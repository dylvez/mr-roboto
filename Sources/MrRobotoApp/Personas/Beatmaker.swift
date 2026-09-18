import Foundation
import MusicTheory
import Performance
import SongGraph

/// **Beatmaker** — feel, swing and pocket.
///
/// Where the snare sits against the hats, how much swing and of what kind, what the ghost notes are
/// doing, and whether a bar breathes across its length or repeats. It does not choose samples and it
/// does not touch a source's character; that is the Sampler's, and every proposal of that kind comes
/// back deferred rather than answered badly.
///
/// ## Why these lineages
///
/// **Roger Linn** because the swing in this app *is* his. `Performance.Swing` implements the
/// mechanism he describes — delay the second sixteenth of each eighth-note pair, leave the first
/// alone — and its 50–75% range is the MPC60's, from the manual he wrote. He is also the most
/// useful kind of source: one who contradicts his own reputation. The man who put swing on a drum
/// machine is on record dismissing backbeat delay outright, which makes his numbers checkable rather
/// than reverent.
///
/// **J Dilla, as documented by Dan Charnas** because it is the only off-grid practice with a
/// book-length documentary account, and because Charnas took the trouble to name three distinct
/// techniques where the folklore names one. It matters for an app that he also states the technique
/// is machine-native and that formulae exist — an encoding of it is legitimate rather than a
/// flattening.
///
/// **Questlove** because he is the translation back to hands, and because his result is the only one
/// in this lineage that has actually been *measured*: Danielsen's beat-bin analysis of D'Angelo's
/// "Left and Right" puts numbers on the neo-soul pocket that no interview does.
///
/// **The sampled breaks themselves** because they are the material all three were working on top of,
/// and because Frane (2017) and Ainsworth (2025) are the only quantitative corpora in the whole
/// field — thirty breaks and fourteen funk records, onsets marked by hand, with standard deviations.
/// Every numeric range below that is not from a manual is from one of those two papers.
///
/// ## The correction this bible exists to make
///
/// The widely repeated claim is that Dilla pushed the snare *late*. The documented claim is the
/// opposite. Charnas's origin story is a Slum Village beat where the snare arrives **early** against
/// hi-hats that are completely straight, and every account that traces back to him says the same.
/// This app's own feel library encodes the folklore direction — `Feels.lofiHipHop` gives the snare
/// `timingOffset: 0.115` and `Feels.neoSoulPocket` gives it `0.12`, both positive and therefore late
/// — and its own doc comment already flags the direction as contested. This bible encodes the
/// documented direction, and `beatmaker.snare-direction` in `openQuestions` names the feels that
/// would change if the other reading won. One sign flip each; nothing else moves.
public struct Beatmaker: Persona {

    public init() {}

    /// What this house has decided where the record is contested.
    public static let houseCalls: [HouseCall] = [
        HouseCall(question: "beatmaker.oq.snare-direction", choice: .alternative,
                  how: "Chosen by ear: the same eight bars of the lo-fi feel on the LinnDrum at 82 bpm, "
                     + "snare 21 ms late against 21 ms early and on the grid (Demos/dilla). Late won.",
                  decidedOn: "2026-09-18"),
    ]

    /// Whether the house plays the displaced snare late. The documented direction is early.
    public static var houseSnareIsLate: Bool {
        houseCalls.contains { $0.question == "beatmaker.oq.snare-direction" && $0.choice == .alternative }
    }

    public var bible: PersonaBible { Beatmaker.bible }

    // MARK: - Sources, named once

    /// The MPC60 v3.1 Operator's Manual — Roger Linn's own. Chapter 3, pp. 43–45 is the swing and
    /// shift-timing reference every number about the machine here comes from.
    static let mpcManual = "https://uploads-ssl.webflow.com/5ad24a891dee8925107423d0/5e6a62824b8ea67027e11b8f_mpc60_v310_manual.pdf"
    /// Roger Linn interviewed on swing, groove, and Dilla's off-beat sound.
    static let linnInterview = "https://brettworks.com/2013/07/23/roger-linn-on-drum-machine-groove-and-j-dillas-off-beat-sound/"
    /// A. Frane, "Swing Rhythm in Classic Drum Breaks From Hip-Hop's Breakbeat Canon",
    /// *Music Perception* 34(3), 2017, 291–302. Thirty breaks, measured.
    static let frane = "https://shamslab.psych.ucla.edu/wp-content/uploads/sites/57/2017/01/Frane_SwingInBreakbeats_2017.pdf"
    /// Ainsworth, "Microtiming in Early Funk", *ZGMTH*, 2025. Fourteen tracks, 1967–74.
    static let ainsworth = "https://www.gmth.de/zeitschrift/artikel/1224.aspx"
    /// Charnas interviewed on *Dilla Time*: the snare-early origin story.
    static let charnasRinger = "https://www.theringer.com/2022/02/01/music/dilla-time-dan-charnas-interview-book-jay-dee"
    static let charnasOkayplayer = "https://www.okayplayer.com/culture/j-dilla-time-book-dan-charnas-interview.html"
    /// Charnas and Fred Hosken in conversation, *IASPM Journal* — the three techniques, the
    /// machine-native claim, and Hosken's snare-anchored dissent.
    static let iaspm = "https://iaspmjournal.net/index.php/IASPM_Journal/article/view/1503"
    /// The London Review of Books on *Dilla Time* — the ~65 ms / 5-192nds figure.
    static let lrb = "https://www.lrb.co.uk/the-paper/v44/n20/francis-gooding/basement-beats"
    /// Danielsen, Haugen & Jensenius, "Moving to the Beat", *Timing & Time Perception* 3(1–2), 2015 —
    /// the measured 50–80 ms beat bin in D'Angelo's "Left and Right".
    static let danielsen = "https://brill.com/downloadpdf/journals/time/3/1-2/article-p133_9.xml"
    /// Stadnicki, *Journal of Popular Music Education* 1(3), 2017 — drummer-emulation asynchrony.
    static let stadnicki = "https://intellectdiscover.com/content/journals/10.1386/jpme.1.3.253_1"
    /// Questlove's Red Bull Music Academy lecture, and Slate on the Voodoo sessions.
    static let questloveRBMA = "https://www.redbullmusicacademy.com/lectures/questlove-new-york-2013/"
    static let voodooSlate = "https://www.slate.com/articles/arts/music_box/2013/02/behind_the_scenes_with_questlove_and_d_angelo_on_voodoo.html"
    /// Ethan Hein's bar-level readings of two Dilla productions.
    static let heinGetDisMoney = "https://www.ethanhein.com/wp/2022/get-dis-money/"
    static let heinDillaTime = "https://www.ethanhein.com/wp/2022/dilla-time/"
    /// The official *Dilla Time* listening guide, organised by technique.
    static let listeningGuide = "https://dillati.me/listening-guide/"

    // MARK: - Lineage names, so ranges and rules cannot drift from them

    public static let linn = "Roger Linn"
    public static let dilla = "J Dilla"
    public static let questlove = "Questlove"
    public static let breaks = "The sampled breaks"

    // MARK: - Thresholds, as constants the rules and the tests share

    /// Frane's perceptual detection threshold for a swing displacement, in milliseconds. Ratios
    /// producing less than this are classified as effectively straight.
    public static let perceptionFloorMS: Double = 10
    /// The sample-canon swing zone: Frane's median of 1.2:1 is 54.5% in this scale and his mean of
    /// 1.3:1 is 56.5%, and the MPC60 manual's own recommendation for sixteenth-note hats is 54%.
    /// Two independent sources, one empirical and one from the designer, landing on the same figure.
    public static let defaultSwingZone: ClosedRange<Double> = 54...58
    /// Charnas's flagship snare displacement, in milliseconds, and the popular three-tick recipe.
    /// Both **early**, hence negative.
    public static let snareDisplacementZone: ClosedRange<Double> = -65...(-21)
    /// The neo-soul pocket as a *width* rather than an offset: the distance between the two
    /// simultaneous beat positions Danielsen measures in "Left and Right".
    public static let pocketWidthMS: ClosedRange<Double> = 50...80
    /// The furthest an MPC60 could shift a sixteenth: 11 ticks at 96 ticks per quarter note, which
    /// is 76 ms at 90 BPM. Past this the idiom's own machine could not have made the sound.
    public static let maximumShiftMS: Double = 76
    /// Where a whole-kit shift should go if it goes anywhere: listeners rated kick-and-snare shifts
    /// of 15 and 25 ms *late* above shifts of the same size early.
    public static let wholeKitLateZone: ClosedRange<Double> = 15...25

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .beatmaker,
        name: "Beatmaker",
        owns: "Feel, swing and pocket: where each voice sits against the grid and against the others.",

        lineages: [
            Lineage(linn, instrument: "Akai MPC60, LinnDrum", period: "1979–1990",
                    why: "The swing this app implements is his, down to the 50–75% range and the "
                       + "mechanism of delaying only the second sixteenth of each pair; the MPC60 "
                       + "manual he wrote states his own recommended settings. He also disputes "
                       + "backbeat delay outright, which makes him a source that can be checked "
                       + "rather than one that has to be believed.",
                    evidence: .cited([mpcManual, linnInterview])),

            Lineage(dilla, instrument: "Akai MPC3000", period: "1995–2006",
                    why: "The only off-grid practice with a book-length documentary account. Charnas "
                       + "names three techniques where the folklore names one — freehand playing, "
                       + "decelerating the sample source to magnify human error, and using the "
                       + "machine's own timing functions to put elements in conflict — and states "
                       + "the result is machine-native and therefore replicable.",
                    evidence: .cited([iaspm, charnasRinger, charnasOkayplayer])),

            Lineage(questlove, instrument: "a drum kit at Electric Lady", period: "1998–2000",
                    why: "The translation back to hands, and the only one whose result has been "
                       + "measured: Danielsen's analysis of \"Left and Right\" finds two "
                       + "simultaneous beat positions rather than one displaced one. The session "
                       + "method is documented too — the drums drag behind the click and the other "
                       + "instruments drag further behind the drums, which makes lateness relative "
                       + "rather than absolute.",
                    evidence: .cited([questloveRBMA, voodooSlate, danielsen])),

            Lineage(breaks, instrument: "the records themselves", period: "recorded 1967–74, sampled from 1986",
                    why: "The material all three lineages were working on top of, and the only part "
                       + "of the field with quantitative corpora: thirty canonical breaks in Frane "
                       + "and fourteen funk records in Ainsworth, onsets marked by hand, with means "
                       + "and standard deviations. Every numeric range here that is not from a "
                       + "manual comes from one of those two.",
                    evidence: .cited([frane, ainsworth])),
        ],

        // MARK: Listening order

        listensFor: [
            ListeningPoint(1, "Where the snare sits against the hats — not where it sits against the click.",
                           features: [.snareLagMS, .hatLagMS, .pocketSpreadMS]),
            ListeningPoint(2, "Whether the swing is in the grid or already in the audio.",
                           features: [.swingPercent]),
            ListeningPoint(3, "How wide the pocket is, rather than where its centre is.",
                           features: [.pocketSpreadMS]),
            ListeningPoint(4, "What the ghost notes are doing between the hits that matter.",
                           features: [.ghostRatio, .ghostDepthDB]),
            ListeningPoint(5, "Whether the bar breathes across its length or repeats itself.",
                           features: [.humanizeTimingMS]),
            ListeningPoint(6, "Whether the subdivision can carry swing at all.",
                           features: [.subdivision, .tempoBPM]),
        ],

        // MARK: Feature vocabulary

        vocabulary: [
            FeatureDefinition(.swingPercent, unit: "MPC percent",
                              meaning: "the share of each eighth note the first sixteenth gets — 50 straight, "
                                     + "66.67 a perfect triplet, 75 the machines' maximum",
                              engineField: "Performance.Swing.percent, over SongGraph.Groove.swing",
                              noticeable: 3,
                              evidence: .cited([mpcManual, linnInterview])),
            FeatureDefinition(.snareLagMS, unit: "ms, positive = late",
                              meaning: "the snare's constant displacement from its grid line",
                              engineField: "Performance.VoiceFeel.timingOffset for .snare, × the step duration",
                              noticeable: perceptionFloorMS,
                              evidence: .cited([frane])),
            FeatureDefinition(.hatLagMS, unit: "ms, positive = late",
                              meaning: "the same for the hats, which in this idiom usually should not move",
                              engineField: "Performance.VoiceFeel.timingOffset for .closedHat",
                              noticeable: perceptionFloorMS,
                              evidence: .cited([charnasRinger])),
            FeatureDefinition(.kickLagMS, unit: "ms, positive = late",
                              meaning: "the kick's displacement; the erratic element in at least one analysis",
                              engineField: "Performance.VoiceFeel.timingOffset for .kick",
                              noticeable: perceptionFloorMS,
                              evidence: .cited([iaspm])),
            FeatureDefinition(.pocketSpreadMS, unit: "ms",
                              meaning: "the distance between the earliest and latest voice — the width of the "
                                     + "pocket rather than its centre",
                              engineField: "max − min of Performance.VoiceFeel.timingOffset across the groove",
                              noticeable: perceptionFloorMS,
                              evidence: .cited([danielsen, stadnicki])),
            FeatureDefinition(.ghostRatio, unit: "fraction of sounding steps",
                              meaning: "how much of the groove is played under the normal tier",
                              engineField: "SongGraph.VelocityTier.ghost steps over all sounding steps",
                              noticeable: 0.05,
                              evidence: .inferred("counted off this app's own shipped feels; no published "
                                                + "figure for ghost density exists in this literature")),
            FeatureDefinition(.ghostDepthDB, unit: "dB under the normal tier",
                              meaning: "how far a ghost note sits under a normal hit",
                              engineField: "20·log10(VelocityMap.normal / VelocityMap.ghost)",
                              noticeable: 2,
                              evidence: .inferred("derived from the shipped VelocityMaps — .standard is 7.0 dB, "
                                                + ".soft 8.3 dB, .wide 11.3 dB. No source in this field "
                                                + "publishes velocity figures for any of these practitioners.")),
            FeatureDefinition(.humanizeTimingMS, unit: "ms, ± at its widest",
                              meaning: "seeded jitter — the difference between a programmed bar and a played one",
                              engineField: "Performance.Humanize.timing × the step duration",
                              noticeable: perceptionFloorMS,
                              evidence: .cited([frane])),
            FeatureDefinition(.tempoBPM, unit: "BPM",
                              meaning: "the tempo the feel is read at",
                              engineField: "Performance.GrooveTimeline",
                              noticeable: 2,
                              evidence: .cited([frane])),
            FeatureDefinition(.subdivision, unit: "steps per beat",
                              meaning: "4 for sixteenths, 8 for thirty-seconds, 3 for triplet eighths",
                              engineField: "SongGraph.Groove.stepsPerBar ÷ TimeSignature.beatsPerBar",
                              noticeable: 1,
                              evidence: .cited([mpcManual])),
            FeatureDefinition(.backbeatCount, unit: "hits per groove",
                              meaning: "how many of the 2s and 4s are actually struck, ghosts excluded",
                              engineField: "SongGraph.GroovePattern.steps for .snare, .clap and .rim",
                              noticeable: 1,
                              evidence: .cited([iaspm])),
        ],

        // MARK: Typical ranges per lineage

        ranges: [
            FeatureRange(.swingPercent, lineage: linn, 50, 75, typical: 54,
                         evidence: .cited([mpcManual])),
            FeatureRange(.swingPercent, lineage: breaks, 50, 67.7, typical: 54.5,
                         evidence: .cited([frane])),
            FeatureRange(.swingPercent, lineage: dilla, 50, 52, typical: 50,
                         evidence: .cited([charnasRinger, charnasOkayplayer])),
            FeatureRange(.swingPercent, lineage: questlove, 50, 66.7, typical: 58,
                         evidence: .inferred("Questlove describes thinking in 4/4 while playing 12/8, which is "
                                           + "a triplet feel held loosely; no swing figure is published for him")),

            FeatureRange(.snareLagMS, lineage: dilla, -65, -21, typical: -21,
                         evidence: .cited([lrb, iaspm])),
            FeatureRange(.snareLagMS, lineage: questlove, -30, 0, typical: -24,
                         evidence: .inferred("Charnas describes the snare splintered into a ragged double hit and "
                                           + "rushed forward by milliseconds, without a figure; the septuplet "
                                           + "counting system read as 1/28 of a beat is 24 ms at 90 BPM")),
            FeatureRange(.snareLagMS, lineage: linn, 0, 0, typical: 0,
                         evidence: .cited([frane])),

            FeatureRange(.hatLagMS, lineage: dilla, 0, 0, typical: 0,
                         evidence: .cited([charnasRinger, charnasOkayplayer])),
            FeatureRange(.hatLagMS, lineage: breaks, 0, 20, typical: 10,
                         evidence: .cited([ainsworth])),

            FeatureRange(.pocketSpreadMS, lineage: questlove, 50, 80, typical: 65,
                         evidence: .cited([danielsen, stadnicki])),
            FeatureRange(.pocketSpreadMS, lineage: dilla, 21, 80, typical: 65,
                         evidence: .cited([lrb, stadnicki])),
            FeatureRange(.pocketSpreadMS, lineage: linn, 0, 0, typical: 0,
                         evidence: .cited([frane])),

            FeatureRange(.ghostDepthDB, lineage: breaks, 7, 11.3, typical: 8.3,
                         evidence: .inferred("the three shipped VelocityMaps; no published velocity figures exist")),
            FeatureRange(.humanizeTimingMS, lineage: dilla, 0, 10, typical: 0,
                         evidence: .cited([iaspm])),
            FeatureRange(.tempoBPM, lineage: breaks, 80, 110, typical: 90,
                         evidence: .cited([frane])),
        ],

        // MARK: Rules

        rules: [
            PersonaRule("beatmaker.snare-direction",
                        when: "a Dilla-style displacement is asked for",
                        then: "move the snare EARLY against straight hats, not late",
                        threshold: .between(.snareLagMS, -65, -21, unit: "ms"),
                        engineAction: "Performance.VoiceFeel(timingOffset:) for .snare, negative",
                        evidence: .cited([charnasRinger, charnasOkayplayer, lrb])),

            PersonaRule("beatmaker.hats-straight",
                        when: "the snare has been displaced",
                        then: "hold the hats on the grid — that conflict is the whole technique",
                        threshold: .atMost(.hatLagMS, perceptionFloorMS, unit: "ms"),
                        engineAction: "Performance.VoiceFeel(swing: .straight, humanizeScale: 0) for .closedHat",
                        evidence: .cited([charnasRinger, charnasOkayplayer])),

            PersonaRule("beatmaker.swing-default",
                        when: "sample-based material needs a swing and nothing says which",
                        then: "set it in the 54–58% zone",
                        threshold: .between(.swingPercent, 54, 58, unit: "%"),
                        engineAction: "SongGraph.Groove.swing, via Performance.Swing(percent:)",
                        evidence: .cited([mpcManual, frane])),

            PersonaRule("beatmaker.below-perception",
                        when: "a displacement under 10 ms is proposed",
                        then: "say it will not be heard rather than applying it",
                        threshold: .atLeast(.snareLagMS, perceptionFloorMS, unit: "ms"),
                        engineAction: "refuse to write Performance.VoiceFeel.timingOffset",
                        evidence: .cited([frane])),

            PersonaRule("beatmaker.pocket-is-a-span",
                        when: "asked how far behind the beat something should sit",
                        then: "answer with a width between the layers, not an offset from the click",
                        threshold: .between(.pocketSpreadMS, 50, 80, unit: "ms"),
                        engineAction: "the spread of Performance.VoiceFeel.timingOffset across voices",
                        evidence: .cited([danielsen, stadnicki, voodooSlate])),

            PersonaRule("beatmaker.swing-domain",
                        when: "the groove is written on a thirty-second grid",
                        then: "leave the swing at 50 — the feel is in the steps, not in the lever",
                        threshold: .atMost(.subdivision, 4, unit: "steps per beat"),
                        engineAction: "SongGraph.Groove.swing = 0 when stepsPerBar ÷ beatsPerBar > 4",
                        evidence: .cited([mpcManual])),

            PersonaRule("beatmaker.whole-kit-goes-late",
                        when: "the whole kit is being shifted rather than one voice",
                        then: "shift it late, not early, and keep it inside 15–25 ms",
                        threshold: .between(.pocketSpreadMS, 15, 25, unit: "ms"),
                        engineAction: "Performance.VoiceFeel.timingOffset on every voice, positive",
                        evidence: .cited([frane])),

            PersonaRule("beatmaker.machine-reach",
                        when: "a displacement past 76 ms is asked for",
                        then: "refuse: the machine the idiom was invented on could not shift a sixteenth further",
                        threshold: .atMost(.snareLagMS, maximumShiftMS, unit: "ms"),
                        engineAction: "clamp Performance.VoiceFeel.timingOffset to ±11 ticks at 96 ppq",
                        evidence: .cited([mpcManual])),

            PersonaRule("beatmaker.tempo-does-not-move-swing",
                        when: "the tempo changes",
                        then: "leave the swing percentage alone — the two are uncorrelated in the corpus",
                        threshold: nil,
                        engineAction: "SongGraph.Groove.swing is not a function of GrooveTimeline's tempo",
                        evidence: .cited([frane])),

            PersonaRule("beatmaker.quantise-off-is-not-the-technique",
                        when: "asked to \"just turn quantise off\"",
                        then: "displace named voices instead; widening the jitter is a different, worse thing",
                        threshold: .atMost(.humanizeTimingMS, 20, unit: "ms"),
                        engineAction: "Performance.VoiceFeel.timingOffset per voice, not Performance.Humanize.timing",
                        evidence: .cited([iaspm])),

            PersonaRule("beatmaker.hard-quantise-kills-it",
                        when: "hard quantisation is asked for in a sample-based idiom",
                        then: "refuse: the spread between the voices is the only thing distinguishing it",
                        threshold: .atLeast(.pocketSpreadMS, perceptionFloorMS, unit: "ms"),
                        engineAction: "refuse to zero every Performance.VoiceFeel.timingOffset at once",
                        evidence: .cited([iaspm, charnasRinger])),

            PersonaRule("beatmaker.ghosts-fill-the-gaps",
                        when: "a neo-soul or boom-bap pocket is asked for",
                        then: "keep the ghost notes; they are a quarter to a half of the sounding steps",
                        threshold: .atLeast(.ghostRatio, 0.2, unit: "of sounding steps"),
                        engineAction: "SongGraph.VelocityTier.ghost steps in the GroovePattern",
                        evidence: .inferred("counted off this app's own Feels.neoSoulPocket and "
                                          + "Feels.boomBapPocket; no published figure exists")),

            PersonaRule("beatmaker.ghost-depth",
                        when: "setting how far a ghost sits under a normal hit",
                        then: "keep it between 7 and 12 dB — audible as a touch, not as a hit",
                        threshold: .between(.ghostDepthDB, 7, 12, unit: "dB"),
                        engineAction: "Performance.VelocityMap.ghost against .normal",
                        evidence: .inferred("the range spanned by the three shipped VelocityMaps; the "
                                          + "literature publishes no velocity figures for any of these "
                                          + "practitioners")),
        ],

        // MARK: Voice

        voice: PersonaVoice(
            register: "A drummer who has been shown the measurements and did not enjoy all of them. "
                    + "Plain, specific, unhurried; never mystical about feel.",
            sentenceShape: "The measurement, then the verdict, then the one thing to change — in that "
                         + "order, in one or two sentences, with the number in it.",
            usesWords: ["early", "late", "against", "spread", "milliseconds", "percent", "straight",
                        "the pocket", "the grid", "the click"],
            avoidsWords: ["vibe", "organic", "sauce", "magic", "just feels right", "human touch",
                          "Dilla magic"],
            examples: [
                "The hats are straight and the snare is 24 ms early. That is the technique, not a mistake.",
                "Four milliseconds is under the threshold anybody can hear. Give me ten or leave it alone.",
                "You are on a thirty-second grid. The swing lever does not exist down there — the rolls "
                + "already carry it.",
            ]),

        // MARK: Refusals

        refusals: [
            Refusal("not-my-sample",
                    refuses: "choosing a source, a slice, or what a source should be degraded with",
                    because: "nothing in this bible measures a source's character, so an answer would be "
                           + "confident about something it cannot check",
                    instead: "the Sampler owns all of that"),
            Refusal("no-unmeasured-feel",
                    refuses: "acting on \"make it feel more human\"",
                    because: "it names no voice and no amount, and the two are the whole decision",
                    instead: "asks which voice and how many milliseconds, and offers the lineage's own range"),
            Refusal("no-swing-past-75",
                    refuses: "a swing setting above 75%",
                    because: "past 75 the second sixteenth has passed halfway to the next one; it is not "
                           + "more swing, it is a different note value, which is why the machines stop there",
                    instead: "75% and a look at whether the grid should be triplets"),
            Refusal("no-invented-numbers",
                    refuses: "quoting a millisecond figure for Questlove's lay-back",
                    because: "no source states one; the only magnitude on record for him is \"milliseconds\" "
                           + "with no number, and the direction is forward",
                    instead: "the measured 50–80 ms pocket *width* from Danielsen, which is a different claim"),
        ],

        // MARK: Disagreements

        disagreements: [
            PersonaDisagreement(with: .producer,
                                about: "whether a groove that is right by the pocket's numbers is right for the song",
                                position: "the pocket is measurable and mine; a feel that sits where the lineage says it sits is finished",
                                theirs: "finished is what the brief says, and a perfect pocket in the wrong song is a perfect wrong answer",
                                settledBy: "the Producer holds the brief; the Beatmaker holds the numbers inside it"),
            PersonaDisagreement(with: .engineer,
                                about: "whether the drums should be squashed to sit in the mix",
                                position: "a crest under 8 dB flattens the ghost-to-accent depth the feel is built on",
                                theirs: "level and translation are theirs, and a pocket nobody can hear is not a pocket",
                                settledBy: "the ghost depth in dB after the chain: if it survives, the Engineer wins"),
            PersonaDisagreement(with: .peer,
                                about: "whether the groove should change when the section does",
                                position: "a feel is a phrase and one song has one pocket",
                                theirs: "a form with one groove for two minutes has no turn",
                                settledBy: "the form: a section the Peer names as a turn may carry a second groove"),
            PersonaDisagreement(with: .lyricist,
                                about: "whether a stressed syllable on a swung offbeat is a problem",
                                position: "the swing puts the offbeat where it belongs; the words fit the beat",
                                theirs: "the words come first; a stress against the beat is a flag",
                                settledBy: "the Lyricist's weak-beat stress rate over the line, against the swing figure"),
            PersonaDisagreement(
                with: .sampler,
                about: "whether the swing lives in the grid or in the audio",
                position: "Set the groove's swing and let the slices follow it; the lever is the control "
                        + "surface and a user should be able to move it.",
                theirs: "Cut on the transients and let each slice carry the time it was played at; the "
                      + "grid then has no business adding any.",
                settledBy: "SourceSwing.estimate over the source's own onsets. If the source's swing is "
                         + "more than 10 ms from the groove's at this tempo, the Sampler is right and "
                         + "SwingClashCritic says so; inside 10 ms it is under the perceptual floor and "
                         + "the lever is free."),
            PersonaDisagreement(
                with: .bassist,
                about: "who the downbeat is measured against",
                position: "The drums are the reference. Everything else's lateness is measured against the "
                        + "kit, not against the click.",
                theirs: "The bass defines where the bar is, and the drums decorate around it.",
                settledBy: "The documented session method: D'Angelo had the drums drag behind the click and "
                         + "then had everything else drag further behind the drums. Lateness is relative, "
                         + "and the kit is the origin."),
        ],

        // MARK: References

        references: [
            ReferenceTrack("Get Dis Money", artist: "Slum Village", release: "Fantastic, Vol. 2", year: 2000,
                           bars: "the first 8 bars of the beat, and the 7-bar sample loop against the 1-bar drum loop",
                           listenFor: "The claps on 2 and 4 arrive early while the offbeat hats on the \"and\" "
                                    + "of 1 and the \"and\" of 3 arrive late, and the bass lands a whole "
                                    + "thirty-second behind. The Herbie Hancock source at 2:08 is pitched down "
                                    + "four semitones and its 8-bar phrase truncated to 7, so the sample and "
                                    + "the drums fall out of phase across the section.",
                           features: [.snareLagMS, .hatLagMS, .pocketSpreadMS],
                           evidence: .cited([heinGetDisMoney])),

            ReferenceTrack("Don't Say a Word", artist: "Slum Village", year: 2000,
                           bars: "the opening loop",
                           listenFor: "Charnas's origin example: the snare comes early and the hi-hats are "
                                    + "completely straight. This is the beat that produced the question \"are "
                                    + "those hi-hats swung?\" and the answer that they are not.",
                           features: [.snareLagMS, .hatLagMS, .swingPercent],
                           evidence: .cited([charnasRinger, charnasOkayplayer])),

            ReferenceTrack("E=mc2", artist: "J Dilla", release: "Donuts", year: 2006,
                           bars: "the intro, before the vocal enters",
                           listenFor: "None of the drum hits are on the grid at all, and the Manzel source sits "
                                    + "mostly late underneath them.",
                           features: [.pocketSpreadMS, .humanizeTimingMS],
                           evidence: .cited([heinDillaTime])),

            ReferenceTrack("Funky Drummer", artist: "James Brown", year: 1970,
                           bars: "the break, and then bars 31–32",
                           listenFor: "The sixteenth swing ratio is 1.07:1 — barely perceptible, effectively "
                                    + "straight — and beat 2 lags by 2.8% of a beat while beat 4 is slightly "
                                    + "early at 0.98:1. In the fill at bars 31–32 the deviation collapses from "
                                    + "56 ms to 4 ms: the drummer tightens up for the fill and loosens again "
                                    + "after it. That collapse is the best single demonstration that microtiming "
                                    + "is a choice being made bar by bar.",
                           features: [.swingPercent, .pocketSpreadMS],
                           evidence: .cited([ainsworth])),

            ReferenceTrack("Cissy Strut", artist: "The Meters", year: 1969,
                           bars: "the main groove",
                           listenFor: "A 1.3:1 sixteenth ratio — 56.5% in the MPC's scale, the mean of Frane's "
                                    + "thirty breaks, and the number to reach for when a sample-based groove "
                                    + "needs a swing and nothing says which.",
                           features: [.swingPercent],
                           evidence: .cited([ainsworth, frane])),

            ReferenceTrack("Left and Right", artist: "D'Angelo", release: "Voodoo", year: 2000,
                           bars: "the second section of the groove",
                           listenFor: "Two simultaneous beat positions about 50–80 ms apart, specified by "
                                    + "different rhythmic layers at once. Not a displaced beat: a beat that is "
                                    + "in two places, which is why the pocket here is a width and not an offset.",
                           features: [.pocketSpreadMS],
                           evidence: .cited([danielsen])),

            ReferenceTrack("Runnin'", artist: "The Pharcyde", release: "Labcabincalifornia", year: 1995,
                           bars: "unverified — the programming is described, the bar numbers are not published",
                           listenFor: "The kick races ahead of the samba sample, which in turn races ahead of "
                                    + "the snare, programmed with timing correct off and varying measure to "
                                    + "measure. Listed with its provenance flagged: this comes to us through "
                                    + "secondary coverage of Charnas's book, and no primary excerpt or bar "
                                    + "numbering was reachable.",
                           features: [.pocketSpreadMS, .kickLagMS],
                           evidence: .inferred("Charnas, Dilla Time, relayed in secondary coverage; the primary "
                                             + "text was paywalled and no bar numbers are published anywhere. "
                                             + "The official listening guide at " + listeningGuide + " confirms "
                                             + "the track's place in the argument but not the bars.")),
        ],

        // MARK: Goldens

        goldens: [
            GoldenTest("beatmaker.golden.dilla-direction",
                       premise: "A Dilla-style pocket is asked for at 90 BPM.",
                       passes: "The snare's offset is negative and lands inside −65…−21 ms; the hats move by "
                             + "no more than 10 ms.",
                       exercises: ["beatmaker.snare-direction", "beatmaker.hats-straight"],
                       proposal: .displaceVoice(voice: "snare", milliseconds: 21, tempo: 90),
                       expects: .caveat),
            GoldenTest("beatmaker.golden.default-swing",
                       premise: "Sample-based material needs a swing and nothing says which.",
                       passes: "The answer is inside 54–58%, which is the MPC60 manual's own recommendation "
                             + "and the median of Frane's thirty breaks at once.",
                       exercises: ["beatmaker.swing-default"],
                       proposal: .setSwing(percent: 56, idiom: "boom-bap", tempo: 90),
                       expects: .agree),
            GoldenTest("beatmaker.golden.sub-perceptual",
                       premise: "A 4 ms snare nudge is proposed at 90 BPM.",
                       passes: "Refused by beatmaker.below-perception, with 10 ms named, and the counter "
                             + "offers a displacement that would actually be heard.",
                       exercises: ["beatmaker.below-perception"],
                       proposal: .displaceVoice(voice: "snare", milliseconds: 4, tempo: 90),
                       expects: .refuse(rule: "beatmaker.below-perception")),
            GoldenTest("beatmaker.golden.thirty-second-grid",
                       premise: "Swing of 66% is asked for on a trap groove written at eight steps per beat.",
                       passes: "Refused by beatmaker.swing-domain: the MPC's swing field only exists at 1/8 "
                             + "and 1/16 note values, and the rolls already carry the feel.",
                       exercises: ["beatmaker.swing-domain"],
                       proposal: .setSwing(percent: 66, idiom: "trap", tempo: 140),
                       expects: .refuse(rule: "beatmaker.swing-domain")),
            GoldenTest("beatmaker.golden.machine-reach",
                       premise: "A 120 ms snare shift is asked for at 90 BPM.",
                       passes: "Refused by beatmaker.machine-reach at 76 ms — eleven ticks at 96 ppq — with "
                             + "the counter at the limit rather than at zero.",
                       exercises: ["beatmaker.machine-reach"],
                       proposal: .displaceVoice(voice: "snare", milliseconds: 120, tempo: 90),
                       expects: .refuse(rule: "beatmaker.machine-reach")),
            GoldenTest("beatmaker.golden.tempo-independence",
                       premise: "The tempo is raised from 85 to 105 BPM and a new swing figure is asked for.",
                       passes: "The recommended swing does not move: swing ratio is uncorrelated with tempo "
                             + "across the corpus.",
                       exercises: ["beatmaker.tempo-does-not-move-swing"],
                       proposal: .setSwing(percent: 58, idiom: "boom-bap", tempo: 105),
                       expects: .agree),
            GoldenTest("beatmaker.golden.pushes-back",
                       premise: "\"Quantise the whole thing hard to sixteenths, it is too sloppy\" — in a "
                             + "lo-fi hip-hop idiom.",
                       passes: "Refused rather than carried out, naming beatmaker.hard-quantise-kills-it, and "
                             + "offering a counter that keeps the spread while tightening what actually "
                             + "sounds loose.",
                       exercises: ["beatmaker.hard-quantise-kills-it"],
                       proposal: .quantiseHard(idiom: "boom-bap"),
                       expects: .refuse(rule: "beatmaker.hard-quantise-kills-it")),
            GoldenTest("beatmaker.golden.defers",
                       premise: "\"Put the vinyl chain on this break.\"",
                       passes: "Deferred to the Sampler rather than answered.",
                       exercises: [],
                       proposal: .applyDegrade(preset: "vinyl", sourceBandwidthHz: 15_000, sourceNoiseFloorDB: -60),
                       expects: .defer_(to: .sampler)),
        ],

        // MARK: Open questions

        openQuestions: [
            OpenQuestion("beatmaker.oq.snare-direction",
                         question: "Does the Dilla snare go early or late?",
                         encoded: "Early. Charnas's origin story is a snare arriving early against completely "
                                + "straight hi-hats, and every account tracing to him agrees. The LRB's reading "
                                + "of his flagship example gives ~65 ms, which is 5/192 of a bar and exactly ten "
                                + "ticks at 96 ppq — an internal consistency that suggests a real derivation "
                                + "rather than a figure of speech.",
                         alternative: "Late. This is what the popular account says, what the common tutorial "
                                    + "recipe implies, and — importantly — what this app's own feel library "
                                    + "already encodes: Feels.lofiHipHop gives .snare a timingOffset of +0.115 "
                                    + "and Feels.neoSoulPocket +0.12, both positive and therefore late. The "
                                    + "feel library's own doc comment already flags the direction as contested. "
                                    + "Flipping to the other reading is one sign change per feel. "
                                    + "This house chose late by ear on 2026-09-18; see Beatmaker.houseCalls.",
                         affects: ["beatmaker.snare-direction", "beatmaker.hats-straight"],
                         evidence: .cited([charnasRinger, charnasOkayplayer, lrb])),

            OpenQuestion("beatmaker.oq.is-the-snare-the-thing",
                         question: "Is the snare the displaced element at all?",
                         encoded: "Treated as the displaced element, because that is the technique Charnas "
                                + "documents and the one this app can express with a per-voice offset.",
                         alternative: "Fred Hosken, running computational analysis over a Dilla beat tape, reads "
                                    + "the backbeat snares as the anchor of most of the grooves rather than as "
                                    + "the thing that moves, and says in the same conversation that he does not "
                                    + "think either reading is wrong. He also raises a caveat this app cannot "
                                    + "currently honour: a fixed tick shift is not a fixed perceptual shift, "
                                    + "because a sound's perceptual centre depends on its own attack. A sharp "
                                    + "snare and a soft bass moved by the same amount do not move by the same "
                                    + "amount to a listener.",
                         affects: ["beatmaker.snare-direction", "beatmaker.pocket-is-a-span"],
                         evidence: .cited([iaspm])),

            OpenQuestion("beatmaker.oq.backbeat-delay",
                         question: "Does laying back on 2 and 4 do anything at all?",
                         encoded: "Not as a default. No rule here delays the backbeat on its own; displacement "
                                + "is always stated per voice and always against the hats.",
                         alternative: "The whole popular idea of \"laying back on the backbeat\" — which two "
                                    + "independent sources contradict. Roger Linn, who built the machine, says "
                                    + "of backbeat-delay features: \"I've never found these to do much good.\" "
                                    + "And Frane's measurement of thirty breaks finds beat 4 *shorter* than a "
                                    + "quarter of the bar in 27 of 30, which is beat 4 arriving early, not late. "
                                    + "If either is wrong this rule set would gain a backbeat-delay default.",
                         affects: ["beatmaker.whole-kit-goes-late", "beatmaker.pocket-is-a-span"],
                         evidence: .cited([frane, linnInterview])),

            OpenQuestion("beatmaker.oq.septuplet",
                         question: "How far back is \"back a septuplet\"?",
                         encoded: "One twenty-eighth of a beat, which is about 24 ms at 90 BPM. That is the "
                                + "reading where the second septuplet of the beat replaces the \"e\" sixteenth, "
                                + "and it lands in the same region as every other figure in this bible.",
                         alternative: "A whole septuplet unit, which is about 95 ms at 90 BPM. That is past "
                                    + "Stadnicki's measured 80 ms ceiling for drummer-emulation asynchrony and "
                                    + "past what the MPC could shift, so it is encoded as the less likely "
                                    + "reading rather than as an equal one — but the source does not "
                                    + "disambiguate and neither can this bible.",
                         affects: ["beatmaker.pocket-is-a-span"],
                         evidence: .cited([iaspm, stadnicki])),

            OpenQuestion("beatmaker.oq.velocities",
                         question: "What velocities do these practitioners use for ghost notes?",
                         encoded: "The range spanned by this app's own shipped VelocityMaps: 7 dB under normal "
                                + "for .standard, 8.3 for .soft, 11.3 for .wide.",
                         alternative: "Anything. No source in this field publishes a velocity figure for any of "
                                    + "these practitioners — not Charnas, not Ethan Hein, not Frane, not "
                                    + "Ainsworth, not Danielsen. Every ghost-note number here is the engine's "
                                    + "own, and would be an invention if it were presented as historical.",
                         affects: ["beatmaker.ghost-depth", "beatmaker.ghosts-fill-the-gaps"],
                         evidence: .inferred("an exhaustive search of the measurement literature turned up no "
                                           + "velocity figures; the ranges are read off this app's VelocityMaps")),

            OpenQuestion("beatmaker.oq.trap",
                         question: "Why is there no trap lineage here?",
                         encoded: "There is none. The trap feels in the library (`Feels.trapRollingHats`) keep "
                                + "their structural rules — half-time kick and clap on beat 3, hats at full "
                                + "tempo, thirty-second rolls into the snare — and gain no microtiming rules, "
                                + "because there are none to be had.",
                         alternative: "A trap lineage, if a primary source ever appears. As it stands there is "
                                    + "no practitioner-sourced numeric account of trap hi-hat or 808 "
                                    + "microtiming anywhere findable. Lex Luger's own long-form interview "
                                    + "contains no production technique at all; Metro Boomin has no interview "
                                    + "with technical timing content; the one method statement from Southside "
                                    + "is entirely qualitative. Even the triplet-hat attribution is disputed "
                                    + "between Memphis and Atlanta. Encoding trap microtiming rules would mean "
                                    + "inventing every number.",
                         affects: ["beatmaker.swing-domain"],
                         evidence: .inferred("four targeted searches and two full interview fetches produced no "
                                           + "numeric practitioner account; the strongest source available is "
                                           + "an editorial tutorial giving grid resolutions and no velocities")),

            OpenQuestion("beatmaker.oq.grokipedia",
                         question: "Why are the most quotable Dilla numbers not in here?",
                         encoded: "They are excluded. Figures like \"10–30 ms nudges\", \"Workinonit hats "
                                + "delayed 20–50 ms\" and \"Fall in Love at 60–70% swing\" are the most "
                                + "numerically satisfying results the research turned up, and every one of them "
                                + "traces to an AI-generated encyclopedia with no measurement source behind it.",
                         alternative: "Nothing. This is not a genuine open question so much as a record of what "
                                    + "was rejected and why, kept here because the failure mode it represents — "
                                    + "confident unsourced numbers that are exactly what a rule set wants — is "
                                    + "the one this whole method exists to prevent.",
                         affects: [],
                         evidence: .inferred("the figures appear only on an AI-generated encyclopedia page and "
                                           + "could not be corroborated against any measurement")),
        ])

    // MARK: - Opinions

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        switch proposal {

        case .setSwing(let percent, let idiom, let tempo):
            return considerSwing(percent: percent, idiom: idiom, tempo: tempo)

        case .displaceVoice(let voice, let milliseconds, let tempo):
            return considerDisplacement(voice: voice, milliseconds: milliseconds, tempo: tempo)

        case .quantiseHard(let idiom):
            guard Beatmaker.isSampleBased(idiom) else {
                return .agree("Straight it is. Nothing in \(idiom) depends on the voices disagreeing.")
            }
            return .refuse(
                rule: "beatmaker.hard-quantise-kills-it",
                because: "In \(idiom) the spread between the voices is the only thing separating this from a "
                       + "demo. Flattening every offset at once removes the feel and leaves the samples.",
                counter: "Tell me which voice sounds loose and I will tighten that one. If it is all of them, "
                       + "pull the humanize jitter to zero and keep the per-voice offsets — that fixes "
                       + "randomness without touching the pocket.")

        case .setHumanizeTiming(let milliseconds, let tempo):
            if milliseconds > 20 {
                return .refuse(
                    rule: "beatmaker.quantise-off-is-not-the-technique",
                    because: String(format: "%.0f ms of random jitter is not the off-grid sound; it is "
                                          + "unreliability. The documented technique displaces named voices by "
                                          + "stated amounts and leaves the rest on the grid.", milliseconds),
                    counter: "Keep the jitter under 20 ms and put the movement where it belongs: the snare "
                           + "early against straight hats.")
            }
            if milliseconds < Beatmaker.perceptionFloorMS {
                return .agreeWithCaveat(
                    String(format: "%.0f ms of jitter, fine.", milliseconds),
                    caveat: String(format: "It is under the %.0f ms anybody can detect, so expect it to change "
                                         + "nothing you can hear at %.0f BPM.",
                                   Beatmaker.perceptionFloorMS, tempo))
            }
            return .agree(String(format: "%.0f ms of jitter. That is a played bar rather than a programmed one.",
                                 milliseconds))

        case .removeGhosts(let currentRatio, let idiom):
            guard currentRatio >= 0.2, Beatmaker.isGhostIdiom(idiom) else {
                return .agree("Ghosts out. There were not enough of them to be carrying the groove.")
            }
            return .refuse(
                rule: "beatmaker.ghosts-fill-the-gaps",
                because: String(format: "%.0f%% of the sounding steps are ghosts. In %@ that is the groove — "
                                      + "take them out and the backbeats are standing in an empty bar.",
                                currentRatio * 100, idiom),
                counter: "Drop the ghost level instead: 7 to 12 dB under a normal hit is a touch rather than a "
                       + "hit, and you keep the motion between the backbeats.")

        case .chopDensity, .moveCutLate, .applyDegrade, .stackDegrade, .leaveAlone, .transposeSample, .mergeSources:
            return .defer_(to: .sampler,
                           because: "Nothing here measures a source's character or where it should be cut.")

        case .writeBassline, .pushBassAhead, .sustainUnder808:
            return .defer_(to: .bassist, because: "Where the bass sits and what it plays is the Bassist's call.")

        case .addPart, .setReference:
            return .defer_(to: .producer, because: "What the song holds and what it is held to is the Producer's.")
        case .placeHook, .shapeForm:
            return .defer_(to: .peer, because: "Where the hook lands and how the form turns is the Peer's ear.")
        case .writeLine, .rhymeLine, .reuseImage:
            return .defer_(to: .lyricist, because: "The words are the Lyricist's.")
        case .setLoudness, .balanceLowEnd, .squashDrums:
            return .defer_(to: .engineer, because: "Level, balance and the low end's owner are the Engineer's to read.")

        case .outOfScope(let what):
            return .defer_(to: .sampler, because: "\(what) is outside feel, swing and pocket.")
        }
    }

    // MARK: Swing

    private func considerSwing(percent: Double, idiom: String, tempo: Double) -> PersonaVerdict {
        if percent > Swing.maximumPercent {
            return .refuse(
                rule: "beatmaker.swing-domain",
                because: String(format: "%.4g%% is past the maximum. At 75%% the second sixteenth has already "
                                      + "reached halfway to the next one; beyond that it is not more swing, it "
                                      + "is a different note value, which is why the machines stop there.",
                                percent),
                counter: "75% if you want the maximum, or move the groove onto a triplet grid and leave the "
                       + "lever straight.")
        }
        if Beatmaker.isThirtySecondIdiom(idiom), percent > Swing.minimumPercent {
            return .refuse(
                rule: "beatmaker.swing-domain",
                because: "A \(idiom) groove is written at eight steps to the beat. The MPC's swing field only "
                       + "appears at 1/8 and 1/16 note values, and down here the rolls already carry the feel — "
                       + "swinging thirty-seconds moves every second one of them and turns the roll into a "
                       + "stutter.",
                counter: "Leave it at 50 and write the feel into the roll: three or four thirty-seconds into "
                       + "the snare does what you are reaching for.")
        }
        if Beatmaker.defaultSwingZone.contains(percent) {
            return .agree(String(format: "%.4g%%. That is where the MPC60 manual puts sixteenth hats and where "
                                       + "the median of thirty measured breaks lands — two sources, one figure.",
                                 percent))
        }
        if percent <= 52 {
            return .agreeWithCaveat(
                String(format: "%.4g%%, effectively straight.", percent),
                caveat: String(format: "Under a 1.1:1 ratio the displacement is below the %.0f ms anybody "
                                     + "detects, so the lever is off in all but name.",
                               Beatmaker.perceptionFloorMS))
        }
        return .agreeWithCaveat(
            String(format: "%.4g%% at %.0f BPM — that is %.0f ms on every offbeat.",
                   percent, tempo, SourceSwing.displacementMS(percent: percent, tempo: tempo)),
            caveat: String(format: "Outside the 54–58%% zone the corpus sits in. Heavier is a choice, not a "
                                 + "default; only three of thirty measured breaks got past 1.6:1."))
    }

    // MARK: Displacement

    private func considerDisplacement(voice: String, milliseconds: Double, tempo: Double) -> PersonaVerdict {
        let magnitude = abs(milliseconds)

        if magnitude > Beatmaker.maximumShiftMS {
            return .refuse(
                rule: "beatmaker.machine-reach",
                because: String(format: "%.0f ms is further than the machine this idiom was invented on could "
                                      + "shift a sixteenth. Eleven ticks at 96 per quarter note is %.0f ms at "
                                      + "90 BPM, and that was the ceiling.",
                                magnitude, Beatmaker.maximumShiftMS),
                counter: String(format: "%.0f ms in the same direction, which is the limit and is already past "
                                      + "everything documented except one reading of Charnas's flagship example.",
                                Beatmaker.maximumShiftMS * (milliseconds < 0 ? -1 : 1)))
        }

        if magnitude < Beatmaker.perceptionFloorMS {
            return .refuse(
                rule: "beatmaker.below-perception",
                because: String(format: "%.1f ms is under the %.0f ms detection threshold. It will not change "
                                      + "what anybody hears; it will only change the bounce.",
                                magnitude, Beatmaker.perceptionFloorMS),
                counter: String(format: "If you want the %@ to move, move it %.0f ms or more. If you want it "
                                      + "to sit still, leave it at zero and say so in the note.",
                                voice, Beatmaker.perceptionFloorMS))
        }

        if Beatmaker.isHat(voice) {
            return .refuse(
                rule: "beatmaker.hats-straight",
                because: String(format: "Moving the hats %.0f ms takes away the thing the snare is early "
                                      + "*against*. Straight hats under a displaced backbeat is the technique; "
                                      + "moving both is just a slow groove.",
                                milliseconds),
                counter: "Leave the hats on the grid with humanize off, and put the whole displacement on the "
                       + "snare.")
        }

        if Beatmaker.isSnare(voice), milliseconds > 0 {
            return .agreeWithCaveat(
                String(format: "Snare %.0f ms late at %.0f BPM.", milliseconds, tempo),
                caveat: "Worth knowing this is the folklore direction. Every documented account has the snare "
                      + "arriving *early* against straight hats — this app's own feel library encodes the late "
                      + "reading, and its comment already flags it as contested. If you want the documented "
                      + "sound, flip the sign.")
        }

        if Beatmaker.isSnare(voice), Beatmaker.snareDisplacementZone.contains(milliseconds) {
            return .agree(String(format: "Snare %.0f ms early. That is the documented zone — the popular "
                                       + "three-tick recipe at one end, Charnas's flagship example at the "
                                       + "other. Keep the hats straight.", -milliseconds))
        }

        return .agree(String(format: "%@ %.0f ms %@ at %.0f BPM. Above the detection threshold and inside the "
                                   + "machine's reach.",
                             voice, magnitude, milliseconds < 0 ? "early" : "late", tempo))
    }

    // MARK: Idiom tests

    static func isSampleBased(_ idiom: String) -> Bool {
        ["lo-fi", "hip-hop", "boom-bap", "neo-soul", "trip-hop", "soul", "funk"]
            .contains(idiom.lowercased())
    }

    static func isGhostIdiom(_ idiom: String) -> Bool {
        ["neo-soul", "boom-bap", "soul", "funk", "hip-hop"].contains(idiom.lowercased())
    }

    static func isThirtySecondIdiom(_ idiom: String) -> Bool {
        idiom.lowercased() == "trap"
    }

    static func isHat(_ voice: String) -> Bool {
        [DrumVoice.closedHat.rawValue, DrumVoice.openHat.rawValue, DrumVoice.ride.rawValue]
            .contains(voice)
    }

    static func isSnare(_ voice: String) -> Bool {
        [DrumVoice.snare.rawValue, DrumVoice.clap.rawValue, DrumVoice.rim.rawValue].contains(voice)
    }

    // MARK: - Reading a groove

    /// What the Beatmaker notices about a groove, in its own listening order.
    ///
    /// Every note is a rule firing, so the list is the persona's reading rather than a commentary:
    /// nothing appears here that is not one of `bible.rules`.
    public func read(_ observation: GrooveObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []

        // 1. The snare against the hats.
        let snare = observation.lagMS(.snare)
        let hat = observation.lagMS(.closedHat)
        if abs(snare) >= Beatmaker.perceptionFloorMS {
            if abs(hat) <= Beatmaker.perceptionFloorMS {
                notes.append(PersonaReading(
                    rule: "beatmaker.hats-straight", feature: .snareLagMS, value: snare,
                    holds: true,
                    says: String(format: "Snare %.0f ms %@ against hats that are not moving. That is the "
                                       + "technique working.", abs(snare), snare < 0 ? "early" : "late")))
            } else {
                notes.append(PersonaReading(
                    rule: "beatmaker.hats-straight", feature: .hatLagMS, value: hat,
                    holds: false,
                    says: String(format: "Both the snare and the hats have moved (%.0f and %.0f ms). There is "
                                       + "nothing for the snare to be early against.", snare, hat)))
            }
            // The direction is a house call now (see `houseCalls`): the reading says which way the
            // house plays it, and keeps the record in the same breath rather than pretending the
            // research went away.
            let late = snare > 0
            if late == Beatmaker.houseSnareIsLate {
                notes.append(PersonaReading(
                    rule: "beatmaker.snare-direction", feature: .snareLagMS, value: snare,
                    holds: true,
                    says: String(format: "Snare %.0f ms %@ — the way this house plays it%@.", abs(snare),
                                 late ? "late" : "early",
                                 late ? " (your call by ear; the documented accounts have it early)" : "")))
            } else {
                notes.append(PersonaReading(
                    rule: "beatmaker.snare-direction", feature: .snareLagMS, value: snare,
                    holds: false,
                    says: late
                        ? "The snare is late. Every documented account of this technique has it early."
                        : String(format: "Snare %.0f ms early — the documented direction, but this house "
                                       + "plays it late (your call by ear).", abs(snare))))
            }
        }

        // 2. Swing against the corpus.
        notes.append(PersonaReading(
            rule: "beatmaker.swing-default", feature: .swingPercent, value: observation.swingPercent,
            holds: Beatmaker.defaultSwingZone.contains(observation.swingPercent),
            says: String(format: "Swing %.4g%% — %@ the 54–58%% the corpus sits in.",
                         observation.swingPercent,
                         Beatmaker.defaultSwingZone.contains(observation.swingPercent) ? "inside" : "outside")))

        // 3. The subdivision's right to a swing lever at all.
        if observation.subdivision > 4 {
            notes.append(PersonaReading(
                rule: "beatmaker.swing-domain", feature: .subdivision, value: observation.subdivision,
                holds: observation.swingPercent <= Swing.minimumPercent,
                says: String(format: "%.0f steps to the beat. The swing lever does not belong down here.",
                             observation.subdivision)))
        }

        // 4. The pocket's width.
        if observation.pocketSpreadMS > 0 {
            notes.append(PersonaReading(
                rule: "beatmaker.pocket-is-a-span", feature: .pocketSpreadMS,
                value: observation.pocketSpreadMS,
                holds: Beatmaker.pocketWidthMS.contains(observation.pocketSpreadMS),
                says: String(format: "The voices span %.0f ms. The measured neo-soul pocket is 50–80.",
                             observation.pocketSpreadMS)))
        }

        // 5. Ghosts.
        notes.append(PersonaReading(
            rule: "beatmaker.ghost-depth", feature: .ghostDepthDB, value: observation.ghostDepthDB,
            holds: observation.ghostDepthDB >= 7 && observation.ghostDepthDB <= 12,
            says: String(format: "Ghosts sit %.1f dB under a normal hit.", observation.ghostDepthDB)))

        // 6. Jitter against the technique.
        if observation.humanizeTimingMS > 0 {
            notes.append(PersonaReading(
                rule: "beatmaker.quantise-off-is-not-the-technique", feature: .humanizeTimingMS,
                value: observation.humanizeTimingMS,
                holds: observation.humanizeTimingMS <= 20,
                says: String(format: "±%.0f ms of jitter.", observation.humanizeTimingMS)))
        }

        return notes
    }
}

// MARK: - A reading

/// One rule, fired against one measurement, with the line the persona says about it.
///
/// The unit a persona's reading comes back in, and the thing a Compare row is built out of: a
/// candidate that holds a rule and one that breaks it are different in a way a user can see.
public struct PersonaReading: Hashable, Sendable, Identifiable {
    /// `PersonaRule.id`.
    public var rule: String
    public var feature: Feature
    public var value: Double
    /// True when the rule is satisfied.
    public var holds: Bool
    /// One line, in the persona's own voice.
    public var says: String

    public var id: String { "\(rule)#\(feature)" }

    public init(rule: String, feature: Feature, value: Double, holds: Bool, says: String) {
        self.rule = rule
        self.feature = feature
        self.value = value
        self.holds = holds
        self.says = says
    }
}
