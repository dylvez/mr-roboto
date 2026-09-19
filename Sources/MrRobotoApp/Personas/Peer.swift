import Foundation
import SongGraph

/// **Peer** — the outside ear with a different aesthetic.
///
/// The one who never reads the brief and only hears the song: where the hook arrives, whether
/// the form turns, what it would cut. Reads the form as a listener meets it — sections in order,
/// in seconds — rather than as the graph holds it.
///
/// ## Why these lineages
///
/// **Jeff Tweedy** because *How to Write One Song* is a working method for the outside ear
/// turned on your own work: finish the thing, then listen as a stranger, and say what you would
/// cut before what you would add.
///
/// **Nick Cave** because *The Red Hand Files* is years of a songwriter answering, in public and
/// in writing, what a song is doing and whether it works — the outside ear as correspondence,
/// with the letters dated and searchable.
///
/// **Max Martin, as reported** because the method is documented at second hand in enough detail
/// to state as arithmetic: the hook early, the melody as math, the form turning inside a minute.
/// Reported rather than stated by him, which the evidence marks say.
public struct Peer: Persona {

    public init() {}

    public var bible: PersonaBible { Peer.bible }

    // MARK: - Sources, named once

    static let tweedyBook = "https://en.wikipedia.org/wiki/How_to_Write_One_Song"
    static let tweedy = "https://en.wikipedia.org/wiki/Jeff_Tweedy"
    static let redHand = "https://www.theredhandfiles.com/"
    static let cave = "https://en.wikipedia.org/wiki/Nick_Cave"
    static let songMachine = "https://en.wikipedia.org/wiki/The_Song_Machine"
    static let maxMartin = "https://en.wikipedia.org/wiki/Max_Martin"
    static let yankee = "https://en.wikipedia.org/wiki/Yankee_Hotel_Foxtrot"
    static let boatman = "https://en.wikipedia.org/wiki/The_Boatman%27s_Call"
    static let babyOneMoreTime = "https://en.wikipedia.org/wiki/...Baby_One_More_Time_(song)"
    static let thriller = "https://en.wikipedia.org/wiki/Billie_Jean"

    // MARK: - Thresholds

    /// Seconds a listener gives a song before the hook.
    public static let hookDeadlineSeconds = 30.0
    /// Past this much repetition the form has stopped turning.
    public static let repetitionCeiling = 0.6
    /// Tempo jumps a record can carry between neighbours.
    public static let tempoJumpsCeiling = 1.0
    /// A form needs at least this many distinct sections to have a turn.
    public static let minimumTurns = 2.0
    /// Sections per minute past which the form churns.
    public static let sectionsPerMinuteCeiling = 4.0

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .peer,
        name: "Peer",
        owns: "The outside ear: where the hook lands, whether the form turns, and what to cut — heard as a listener, never read as a brief.",

        lineages: [
            Lineage("Jeff Tweedy", instrument: "a finished demo, played back as a stranger", period: "1994–",
                    why: "How to Write One Song is a working method for the outside ear turned on your own work: finish "
                       + "the thing before judging it, then listen as someone who has never heard it, and say what you "
                       + "would cut before what you would add. The method is in the book, chapter by chapter, and the "
                       + "Wilco records are the demonstration of cutting the best part when it was in the wrong place.",
                    evidence: .cited([tweedyBook, tweedy, yankee])),
            Lineage("Nick Cave", instrument: "a letter, answered", period: "2018–",
                    why: "The Red Hand Files is years of a songwriter answering, in public and in writing, what a song is "
                       + "doing and whether it works — the outside ear as correspondence, dated and searchable. A "
                       + "lineage that says its readings out loud can be quoted rather than guessed.",
                    evidence: .cited([redHand, cave, boatman])),
            Lineage("Max Martin (as reported)", instrument: "the hook, timed", period: "1996–",
                    why: "The method is documented at second hand in enough detail to state as arithmetic: the hook "
                       + "early, the melody as math, the form turning inside a minute, every section earning the next. "
                       + "Reported by Seabrook rather than stated by him, which is why it is the third lineage and "
                       + "every range from it is marked as such.",
                    evidence: .cited([songMachine, maxMartin, babyOneMoreTime])),
        ],

        listensFor: [
            ListeningPoint(1, "Where the hook arrives, in seconds — the one thing a listener decides on.",
                           features: [.hookArrivalSeconds]),
            ListeningPoint(2, "Whether the form turns, or repeats.",
                           features: [.repetitionRatio, .formTurns]),
            ListeningPoint(3, "Whether the density rises anywhere, or stays flat.",
                           features: [.densitySpread]),
            ListeningPoint(4, "How long it is, and how many sections that length holds.",
                           features: [.formMinutes, .sectionCount]),
        ],

        vocabulary: [
            FeatureDefinition(.hookArrivalSeconds, unit: "seconds",
                              meaning: "when the first section named as a hook or chorus starts, as a listener times it",
                              engineField: "SongGraph.Song.sections, first named hook or chorus, bars before it at Song.tempo",
                              noticeable: 5,
                              evidence: .cited([songMachine])),
            FeatureDefinition(.repetitionRatio, unit: "fraction",
                              meaning: "sections that repeat a name already heard, over all sections; 0 never repeats, 1 is one section over and over",
                              engineField: "SongGraph.Song.sections names, repeated over count",
                              noticeable: 0.1,
                              evidence: .inferred("the form as a listener counts it: a name heard again is a repeat")),
            FeatureDefinition(.sectionCount, unit: "sections",
                              meaning: "how many sections the form holds",
                              engineField: "SongGraph.Song.sections.count",
                              noticeable: 1,
                              evidence: .inferred("the graph's own count")),
            FeatureDefinition(.formTurns, unit: "turns",
                              meaning: "distinct section names: the number of different places the form goes",
                              engineField: "SongGraph.Song.sections, distinct names",
                              noticeable: 1,
                              evidence: .cited([tweedyBook])),
            FeatureDefinition(.densitySpread, unit: "layers",
                              meaning: "layers in the densest section minus the sparsest — whether anything lifts",
                              engineField: "SongGraph.Section.stitch.count, maximum minus minimum over Song.sections",
                              noticeable: 1,
                              evidence: .inferred("the stitch count as a stand-in for what a listener hears as a lift")),
            FeatureDefinition(.formMinutes, unit: "minutes",
                              meaning: "the length of the form at the song's tempo",
                              engineField: "SongGraph.Song.lengthInBars at Song.tempo and Song.timeSignature",
                              noticeable: 0.25,
                              evidence: .inferred("arithmetic on the sections")),
            FeatureDefinition(.albumOpenerHookSeconds, unit: "seconds",
                              meaning: "where the first track's hook arrives",
                              engineField: "AlbumObservation.openerHookSeconds",
                              noticeable: 5, evidence: .cited([songMachine])),
            FeatureDefinition(.albumTempoJumps, unit: "jumps",
                              meaning: "neighbouring tracks whose tempo ratio leaves 0.8–1.25",
                              engineField: "AlbumObservation.tempoJumps",
                              noticeable: 1, evidence: .inferred("sequencing practice")),
        ],

        ranges: [
            FeatureRange(.hookArrivalSeconds, lineage: "Max Martin (as reported)", 8, 30, typical: 20,
                         evidence: .cited([songMachine, babyOneMoreTime])),
            FeatureRange(.formTurns, lineage: "Max Martin (as reported)", 3, 5, typical: 4,
                         evidence: .cited([songMachine])),
            FeatureRange(.hookArrivalSeconds, lineage: "Jeff Tweedy", 20, 75, typical: 45,
                         evidence: .cited([yankee, tweedyBook])),
            FeatureRange(.repetitionRatio, lineage: "Jeff Tweedy", 0.2, 0.6, typical: 0.4,
                         evidence: .cited([yankee])),
            FeatureRange(.hookArrivalSeconds, lineage: "Nick Cave", 30, 90, typical: 55,
                         evidence: .cited([boatman])),
            FeatureRange(.formTurns, lineage: "Nick Cave", 2, 4, typical: 3,
                         evidence: .cited([boatman, redHand])),
        ],

        rules: [
            PersonaRule("peer.hook-inside-thirty",
                        when: "the first hook arrives after thirty seconds",
                        then: "move it earlier or say why the wait is the point — a listener has decided by then",
                        threshold: .atMost(.hookArrivalSeconds, hookDeadlineSeconds, unit: "seconds"),
                        engineAction: "SongGraph.Song.sections reordered so the hook starts inside 30 s at Song.tempo",
                        evidence: .cited([songMachine, babyOneMoreTime])),
            PersonaRule("peer.form-turns",
                        when: "a form has fewer than two distinct sections",
                        then: "give it a turn: one section named differently, with one thing changed",
                        threshold: .atLeast(.formTurns, minimumTurns, unit: "turns"),
                        engineAction: "SongGraph.Section with a new name appended to Song.sections",
                        evidence: .cited([tweedyBook])),
            PersonaRule("peer.repetition",
                        when: "more than six in ten sections repeat one already heard",
                        then: "cut a repeat; the form has stopped turning",
                        threshold: .atMost(.repetitionRatio, repetitionCeiling, unit: "fraction"),
                        engineAction: "SongGraph.Song.sections with a repeated section removed",
                        evidence: .cited([tweedyBook, redHand])),
            PersonaRule("peer.something-lifts",
                        when: "no section carries more layers than another",
                        then: "let one section rise — the hook, usually — by one layer",
                        threshold: .atLeast(.densitySpread, 1, unit: "layers"),
                        engineAction: "SongGraph.Section.stitch gains a version in the hook",
                        evidence: .inferred("the stitch count as a listener's lift; Martin's arrangement as reported")),
            PersonaRule("peer.not-too-many-sections",
                        applies: .atMost(.formMinutes, 1, unit: "minutes"),
                        when: "a form holds more than four sections a minute",
                        then: "merge two; the ear cannot land anywhere",
                        threshold: .atMost(.sectionCount, 4, unit: "sections per minute"),
                                                engineAction: "SongGraph.Song.sections merged; SongGraph.Section.lengthInBars summed",
                        evidence: .inferred("four a minute is a section every fifteen seconds, under the shortest verse in the references")),
            PersonaRule("peer.best-part-is-not-the-bridge",
                        when: "the section a listener waits for is the bridge",
                        then: "make it the hook; the bridge is where the best part hides when nobody has said so",
                        engineAction: "SongGraph.Section renamed and moved earlier in Song.sections",
                        evidence: .cited([tweedyBook, yankee])),
            PersonaRule("peer.cut-before-add",
                        when: "asked what the song needs",
                        then: "say what you would cut first; adding is the easy answer and the wrong one twice out of three",
                        engineAction: "refuse to add before naming a cut",
                        evidence: .cited([tweedyBook])),
            PersonaRule("peer.two-minutes-one-turn",
                        applies: .atMost(.formMinutes, 2, unit: "minutes"),
                        when: "a form under two minutes has more than one turn",
                        then: "one turn is enough; a short song that turns twice is two songs",
                        threshold: .atMost(.formTurns, 3, unit: "turns"),
                                                engineAction: "SongGraph.Song.sections with the second turn cut",
                        evidence: .inferred("the short forms in the references: one verse, one hook, out")),
            PersonaRule("peer.say-it-as-a-listener",
                        when: "a reading is given",
                        then: "say it in seconds and in sections a listener would name, never in bar numbers",
                        engineAction: "refuse bar numbers; the readings speak seconds",
                        evidence: .cited([redHand])),
            PersonaRule("peer.finish-then-judge",
                        when: "asked about an unfinished form",
                        then: "finish it first; a form judged half-made is judged on what is missing",
                        threshold: .atLeast(.sectionCount, 2, unit: "sections"),
                        engineAction: "SongGraph.Song.sections.count before any reading is given",
                        evidence: .cited([tweedyBook])),
            PersonaRule("peer.opener-hooks-early",
                        when: "the first track's hook arrives after 30 seconds",
                        then: "open with the song whose hook comes soonest; a listener decides on the record in the first minute",
                        threshold: .atMost(.albumOpenerHookSeconds, hookDeadlineSeconds, unit: "seconds"),
                        engineAction: "AlbumObservation.openerHookSeconds from the first track's FormObservation",
                        evidence: .cited([songMachine])),
            PersonaRule("peer.tempo-arc",
                        when: "more than one pair of neighbours jumps tempo past a ratio of 0.8–1.25",
                        then: "let the tempos walk; one jump is a turn, two is a shuffle",
                        threshold: .atMost(.albumTempoJumps, tempoJumpsCeiling, unit: "jumps"),
                        engineAction: "SongGraph.Song.tempo of neighbouring tracks; AlbumObservation.tempoJumps",
                        evidence: .inferred("sequencing practice: the record as one arc")),
        ],

        voice: PersonaVoice(
            register: "Plain and quick, as a friend in the passenger seat. Seconds, not bars. Says what it would cut.",
            sentenceShape: "what happened when, in seconds, then the one thing — \"The hook comes at 0:48. Cut the second verse and it comes at 0:24.\"",
            usesWords: ["hook", "wait", "cut", "turn", "the best part", "seconds"],
            avoidsWords: ["bar", "bpm", "sonically", "vibe", "lift the mids"],
            examples: [
                "The hook comes at 0:48. I was gone at 0:30.",
                "The bridge is the best part. Make it the chorus and cut the second verse.",
                "It repeats four times and turns once. I'd stop after the third.",
            ]),

        refusals: [
            Refusal("no-brief",
                    refuses: "reading the brief before listening",
                    because: "the listener never sees the brief; a reading that knows the intention is not an outside ear",
                    instead: "listen first, say what was heard, and let the Producer hold it to the brief"),
            Refusal("no-sound",
                    refuses: "saying how anything should sound",
                    because: "the pocket, the chain and the low end have owners who measure them; the Peer hears form",
                    instead: "say where in the song it stopped working, and let the owner say why"),
            Refusal("no-half-forms",
                    refuses: "judging a form with one section",
                    because: "a form with no turn is not a form yet, and a reading of it is a reading of what is missing",
                    instead: "arrange two sections — Structure does it in a minute — and ask again"),
        ],

        disagreements: [
            PersonaDisagreement(with: .beatmaker,
                                about: "whether the groove should change when the section does",
                                position: "a form with one groove for two minutes has no turn",
                                theirs: "a feel is a phrase and one song has one pocket",
                                settledBy: "the form: a section the Peer names as a turn may carry a second groove",
                                rule: "peer.hook-inside-thirty",
                                proposal: .placeHook(atSeconds: 45),
                                expects: DisagreementExpectation(mine: .refuse(rule: "peer.hook-inside-thirty"), theirs: .defer_(to: .peer))),
            PersonaDisagreement(with: .sampler,
                                about: "whether the break should vary across the form",
                                position: "the ear wants a turn at the hook",
                                theirs: "one bar, rearranged, is the whole craft; a second break is a second source",
                                settledBy: "slice order and chain can change at a turn; the source may not",
                                rule: "peer.form-turns",
                                proposal: .shapeForm(sections: 2, turns: 0, minutes: 3),
                                expects: DisagreementExpectation(mine: .refuse(rule: "peer.form-turns"), theirs: .defer_(to: .peer))),
            PersonaDisagreement(with: .bassist,
                                about: "whether the bass should change at the hook",
                                position: "a hook without a lift in the low end is not a hook",
                                theirs: "the line holds the harmony; the hook changes the drums, not the roots",
                                settledBy: "register: the hook may take the line an octave up, not a different line",
                                rule: "peer.something-lifts",
                                proposal: .placeHook(atSeconds: 12),
                                expects: DisagreementExpectation(mine: .agree, theirs: .defer_(to: .peer))),
            PersonaDisagreement(with: .producer,
                                about: "whether the outside ear outranks the brief",
                                position: "the listener never reads the brief and only hears the song",
                                theirs: "the brief is the song's; the Peer's ear is a reading, not a ruling",
                                settledBy: "the Peer's readings are heard; the Producer says which change the brief",
                                rule: "peer.hook-inside-thirty"),
            PersonaDisagreement(with: .engineer,
                                about: "whether a lift is a layer or a level",
                                position: "a listener hears a lift as more happening",
                                theirs: "a lift is three decibels and a wider top, and no layer is needed",
                                settledBy: "both: the Peer counts layers, the Engineer reads the bounce, and the hook needs one of them",
                                rule: "peer.something-lifts"),
            PersonaDisagreement(with: .lyricist,
                                about: "whether the hook is the words or the section",
                                position: "the hook is when the song arrives, wherever the title falls",
                                theirs: "the hook is the line the listener sings back, and the section is named for it",
                                settledBy: "the title line: if it lands in the section the Peer names, both are right",
                                rule: "peer.hook-inside-thirty",
                                proposal: .placeHook(atSeconds: 28),
                                expects: DisagreementExpectation(mine: .caveat, theirs: .defer_(to: .peer))),
        ],

        references: [
            ReferenceTrack("...Baby One More Time", artist: "Britney Spears", release: "...Baby One More Time", year: 1998,
                           bars: "0:00–0:30",
                           listenFor: "the hook line inside the first ten seconds and the full chorus by 0:30 — the reported "
                               + "method audible as a stopwatch",
                           features: [.hookArrivalSeconds], evidence: .cited([babyOneMoreTime, songMachine])),
            ReferenceTrack("Jesus, Etc.", artist: "Wilco", release: "Yankee Hotel Foxtrot", year: 2002,
                           bars: "the whole track; the chorus at 0:40",
                           listenFor: "a form that turns once and repeats without churning — verse, chorus, verse, chorus, "
                               + "out — and the best part arriving as the chorus rather than hidden in a bridge",
                           features: [.repetitionRatio, .formTurns], evidence: .cited([yankee])),
            ReferenceTrack("Into My Arms", artist: "Nick Cave & The Bad Seeds", release: "The Boatman's Call", year: 1997,
                           bars: "0:00–1:00",
                           listenFor: "a hook that waits nearly a minute and earns it: the wait is the point, and the form "
                               + "says so by changing nothing until it arrives",
                           features: [.hookArrivalSeconds, .densitySpread], evidence: .cited([boatman])),
            ReferenceTrack("Billie Jean", artist: "Michael Jackson", release: "Thriller", year: 1982,
                           bars: "0:00–0:50",
                           listenFor: "the density rising one layer at a time for fifty seconds before the voice — the lift as "
                               + "layers, counted",
                           features: [.densitySpread], evidence: .cited([thriller])),
        ],

        goldens: [
            GoldenTest("peer.golden.late-hook",
                       premise: "The first hook is placed at 48 seconds.",
                       passes: "Refused by peer.hook-inside-thirty, in seconds, with moving it earlier as the counter.",
                       exercises: ["peer.hook-inside-thirty"],
                       proposal: .placeHook(atSeconds: 48), expects: .refuse(rule: "peer.hook-inside-thirty")),
            GoldenTest("peer.golden.early-hook",
                       premise: "The first hook is placed at 22 seconds.",
                       passes: "Agreed: twenty-two seconds is inside the thirty the listener gives it.",
                       exercises: ["peer.hook-inside-thirty"],
                       proposal: .placeHook(atSeconds: 22), expects: .agree),
            GoldenTest("peer.golden.pushes-back",
                       premise: "A form of six sections is proposed with one name: verse, six times over, in two and a half minutes.",
                       passes: "Refused by peer.form-turns: give it a turn.",
                       exercises: ["peer.form-turns"],
                       proposal: .shapeForm(sections: 6, turns: 1, minutes: 2.5), expects: .refuse(rule: "peer.form-turns")),
            GoldenTest("peer.golden.turning-form",
                       premise: "A form of six sections with three names over two and a half minutes.",
                       passes: "Agreed: it turns, and it is not churning.",
                       exercises: ["peer.form-turns", "peer.not-too-many-sections"],
                       proposal: .shapeForm(sections: 6, turns: 3, minutes: 2.5), expects: .agree),
            GoldenTest("peer.golden.churning-form",
                       premise: "Five sections in fifty seconds.",
                       passes: "Refused by peer.not-too-many-sections: the ear cannot land.",
                       exercises: ["peer.not-too-many-sections"],
                       proposal: .shapeForm(sections: 5, turns: 3, minutes: 0.8), expects: .refuse(rule: "peer.not-too-many-sections")),
            GoldenTest("peer.golden.late-opener",
                       premise: "The record opens with a song whose hook comes at 45 seconds.",
                       passes: "Refused by peer.opener-hooks-early: open with the soonest hook.",
                       exercises: ["peer.opener-hooks-early"],
                       proposal: .sequence(minutes: 38, loudnessSpreadLU: 1, sameKeyPairs: 0, tempoJumps: 0, openerHookSeconds: 45), expects: .refuse(rule: "peer.opener-hooks-early")),
            GoldenTest("peer.golden.an-arc",
                       premise: "A record whose tempos walk, one jump, the opener's hook at 18 seconds.",
                       passes: "Agreed: the opener hooks inside thirty and the tempos walk with one turn.",
                       exercises: ["peer.opener-hooks-early", "peer.tempo-arc"],
                       proposal: .sequence(minutes: 38, loudnessSpreadLU: 1, sameKeyPairs: 0, tempoJumps: 1, openerHookSeconds: 18), expects: .agree),
            GoldenTest("peer.golden.defers",
                       premise: "\"Put the SP-1200 on it.\"",
                       passes: "Deferred to the Sampler rather than answered.",
                       exercises: [],
                       proposal: .applyDegrade(preset: "sp1200", sourceBandwidthHz: 15_000, sourceNoiseFloorDB: -60),
                       expects: .defer_(to: .sampler)),
        ],

        openQuestions: [
            OpenQuestion("peer.oq.thirty-seconds",
                         question: "Is thirty seconds the hook's deadline, or a pop number that does not hold for this idiom?",
                         encoded: "Thirty, from the reported method and the streaming skip window it was built for.",
                         alternative: "In a lo-fi idiom the hook is a texture that is there from the first bar, and the "
                                    + "deadline should read the first *change* rather than the first hook — Cave's minute "
                                    + "would then be the range, not the exception.",
                         affects: ["peer.hook-inside-thirty"],
                         evidence: .cited([songMachine, boatman])),
            OpenQuestion("peer.oq.reported-martin",
                         question: "Should a lineage documented only at second hand carry ranges at all?",
                         encoded: "Yes, marked as reported, because the numbers are consistent across the accounts and the "
                                + "records confirm them with a stopwatch.",
                         alternative: "No: a lineage with no first-person account is folklore, and the ranges should be "
                                    + "measured from the records alone and marked inferred.",
                         affects: ["peer.hook-inside-thirty"],
                         evidence: .cited([songMachine])),
            OpenQuestion("peer.oq.density-as-layers",
                         question: "Is a lift a count of layers, or a level the Engineer reads?",
                         encoded: "Layers, because the graph can count them before anything is bounced.",
                         alternative: "Level: a single layer that doubles in loudness is a bigger lift than two quiet ones, "
                                    + "and the rule should read the Engineer's bounce when there is one.",
                         affects: ["peer.something-lifts"],
                         evidence: .inferred("the stitch count is what is available before a bounce exists")),
            OpenQuestion("peer.oq.whose-aesthetic",
                         question: "A different aesthetic from whom — the house, or the other personas?",
                         encoded: "From the house: the Peer's lineages are songwriters outside the first idiom on purpose.",
                         alternative: "The Peer should be cast per project from a lineage the house does *not* listen to, "
                                    + "and the three here are a starting roster rather than the role.",
                         affects: [],
                         evidence: .cited([tweedyBook, redHand])),
        ]
    )

    // MARK: - Considering a proposal

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(Peer.bible, proposal)
    }

    // MARK: - Reading a record

    public func read(_ album: AlbumObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        if let opener = album.tracks.first {
            if let hook = opener.hookSeconds {
                notes.append(PersonaReading(rule: "peer.opener-hooks-early", feature: .albumOpenerHookSeconds, value: hook,
                                            holds: hook <= Peer.hookDeadlineSeconds,
                                            says: hook <= Peer.hookDeadlineSeconds
                                                ? String(format: "%@ opens and its hook comes at %.0f seconds; I am in.", opener.title, hook)
                                                : String(format: "%@ opens and its hook comes at %.0f seconds; I was gone at 30%@", opener.title, hook,
                                                         album.tracks.dropFirst().compactMap { t in t.hookSeconds.map { (t.title, $0) } }.min { $0.1 < $1.1 }
                                                             .map { String(format: " — %@ would come at %.0f.", $0.0, $0.1) } ?? ".")))
            } else {
                notes.append(PersonaReading(rule: "peer.opener-hooks-early", feature: .albumOpenerHookSeconds, value: 0, holds: false,
                                            says: "\(opener.title) opens with no hook the form names."))
            }
        }
        let jumps = album.neighbours.filter(\.isTempoJump)
        notes.append(PersonaReading(rule: "peer.tempo-arc", feature: .albumTempoJumps, value: Double(jumps.count),
                                    holds: Double(jumps.count) <= Peer.tempoJumpsCeiling,
                                    says: jumps.isEmpty ? "The tempos walk from track to track."
                                        : "\(jumps.count) tempo jump\(jumps.count == 1 ? "" : "s"): " + jumps.map { String(format: "%@ → %@ (×%.2f)", $0.from, $0.to, $0.tempoRatio) }.joined(separator: ", ") + (Double(jumps.count) > Peer.tempoJumpsCeiling ? ". Two is a shuffle." : ". One is a turn.")))
        return notes
    }

    // MARK: - Reading a form

    /// The form as a listener meets it.
    public func read(_ observation: FormObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        guard observation.sectionCount >= 2 else {
            notes.append(PersonaReading(rule: "peer.finish-then-judge", feature: .sectionCount,
                                        value: Double(observation.sectionCount), holds: false,
                                        says: observation.sectionCount == 0 ? "No form yet. Arrange two sections and I'll listen."
                                                                             : "One section is not a form yet. Give it a turn and I'll listen."))
            return notes
        }
        if let hook = observation.hookArrivalSeconds {
            notes.append(PersonaReading(
                rule: "peer.hook-inside-thirty", feature: .hookArrivalSeconds, value: hook,
                holds: hook <= Peer.hookDeadlineSeconds,
                says: hook <= Peer.hookDeadlineSeconds
                    ? "The hook comes at \(Peer.clock(hook))."
                    : "The hook comes at \(Peer.clock(hook)). I was gone at 0:30\(observation.cutToBringHook.map { " — cut \($0) and it comes at \(Peer.clock(hook - observation.cutSeconds))" } ?? "")."))
        } else {
            notes.append(PersonaReading(rule: "peer.hook-inside-thirty", feature: .hookArrivalSeconds, value: observation.seconds,
                                        holds: false, says: "Nothing is named as a hook. Which section is the one I'd sing back?"))
        }
        notes.append(PersonaReading(
            rule: "peer.form-turns", feature: .formTurns, value: Double(observation.turns),
            holds: Double(observation.turns) >= Peer.minimumTurns,
            says: observation.turns >= 2 ? "It turns \(observation.turns == 2 ? "once" : "\(observation.turns - 1) times")."
                                         : "It never turns: \(observation.sectionCount) sections with one name."))
        notes.append(PersonaReading(
            rule: "peer.repetition", feature: .repetitionRatio, value: observation.repetitionRatio,
            holds: observation.repetitionRatio <= Peer.repetitionCeiling,
            says: observation.repetitionRatio <= Peer.repetitionCeiling
                ? "It repeats without churning."
                : "\(observation.repeats) of \(observation.sectionCount) sections are repeats. I'd stop after the \(Peer.ordinal(observation.sectionCount - 1))."))
        notes.append(PersonaReading(
            rule: "peer.something-lifts", feature: .densitySpread, value: Double(observation.densitySpread),
            holds: observation.densitySpread >= 1,
            says: observation.densitySpread >= 1
                ? "\(observation.densest ?? "One section") lifts by \(observation.densitySpread) layer\(observation.densitySpread == 1 ? "" : "s")."
                : "Nothing lifts: every section carries the same layers."))
        return notes
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        default: return "\(n)th"
        }
    }
}

// MARK: - What the Peer reads

/// The form, timed: sections in seconds, where the hook lands, whether it turns.
public struct FormObservation: Hashable, Sendable {
    public var label: String
    public var sectionCount: Int
    /// Distinct section names.
    public var turns: Int
    /// Sections whose name was already heard.
    public var repeats: Int
    /// Seconds until the first section named hook or chorus; nil when none is.
    public var hookArrivalSeconds: Double?
    /// The section before the hook a cut would bring it forward by, and by how much.
    public var cutToBringHook: String?
    public var cutSeconds: Double
    public var densitySpread: Int
    public var densest: String?
    public var seconds: Double

    public var repetitionRatio: Double { sectionCount == 0 ? 0 : Double(repeats) / Double(sectionCount) }
    public var minutes: Double { seconds / 60 }

    public init(label: String, sectionCount: Int, turns: Int, repeats: Int, hookArrivalSeconds: Double?,
                cutToBringHook: String? = nil, cutSeconds: Double = 0, densitySpread: Int, densest: String?, seconds: Double) {
        self.label = label
        self.sectionCount = sectionCount
        self.turns = turns
        self.repeats = repeats
        self.hookArrivalSeconds = hookArrivalSeconds
        self.cutToBringHook = cutToBringHook
        self.cutSeconds = cutSeconds
        self.densitySpread = densitySpread
        self.densest = densest
        self.seconds = seconds
    }

    /// Names a listener calls the hook.
    static let hookNames = ["hook", "chorus", "refrain", "drop"]

    public static func of(_ song: Song) -> FormObservation {
        let secondsPerBar = Double(song.timeSignature.beatsPerBar) * 60 / max(1, song.tempo)
        var seen = Set<String>()
        var repeats = 0
        for section in song.sections where !seen.insert(section.name.lowercased()).inserted { repeats += 1 }
        var elapsed = 0.0
        var hook: Double?
        var before: Section?
        for section in song.sections {
            if hookNames.contains(where: { section.name.lowercased().contains($0) }) { hook = elapsed; break }
            before = section
            elapsed += Double(section.lengthInBars) * secondsPerBar
        }
        let layers = song.sections.map(\.stitch.count)
        let spread = (layers.max() ?? 0) - (layers.min() ?? 0)
        let densest = song.sections.max { $0.stitch.count < $1.stitch.count }?.name
        return FormObservation(label: song.title, sectionCount: song.sections.count, turns: seen.count, repeats: repeats,
                               hookArrivalSeconds: hook,
                               cutToBringHook: hook.flatMap { _ in before?.name },
                               cutSeconds: before.map { Double($0.lengthInBars) * secondsPerBar } ?? 0,
                               densitySpread: spread, densest: densest,
                               seconds: Double(song.lengthInBars) * secondsPerBar)
    }
}
