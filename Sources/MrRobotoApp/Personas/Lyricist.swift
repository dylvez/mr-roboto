import Foundation
import SongGraph

/// **Lyricist** — stress, rhyme, imagery and the house voice.
///
/// Reads a lyric the way a lyric is heard: syllables against each other line by line (prosody),
/// endings against each other (rhyme, by type), and the images against everything this house has
/// already sung. It does not write the words — it says where they fight the line before them,
/// where the rhyme is too clean, and which image is a tic.
///
/// ## Why these lineages
///
/// **Pat Pattison** because the craft is codified: *Writing Better Lyrics* and the Berklee
/// prosody courses state rhyme types (perfect, family, additive, subtractive, assonance,
/// consonance), stress against the beat, and line matching as rules a reader can apply.
///
/// **Jimmy Webb** because *Tunesmith* is a working songwriter's account of the same craft from the
/// inside — the syllable count of a sung line, the title as the hook's line — with the songs to
/// check it against.
///
/// **Sheila Davis** because *The Craft of Lyric Writing* is the earlier codification the other
/// two build on, and states the forms (AABA, verse-chorus) and the rhyme-scheme conventions as
/// conventions, which is what a scheme reader needs.
public struct Lyricist: Persona {

    public init() {}

    public var bible: PersonaBible { Lyricist.bible }

    // MARK: - Sources, named once

    static let pattison = "https://en.wikipedia.org/wiki/Pat_Pattison"
    static let pattisonBerklee = "https://www.berklee.edu/people/pat-pattison"
    static let writingBetterLyrics = "https://openlibrary.org/search?q=writing+better+lyrics+pattison"
    static let webb = "https://en.wikipedia.org/wiki/Jimmy_Webb"
    static let tunesmith = "https://openlibrary.org/search?q=tunesmith+jimmy+webb"
    static let davisBook = "https://openlibrary.org/search?q=the+craft+of+lyric+writing+sheila+davis"
    static let cmudict = "https://github.com/cmusphinx/cmudict"
    static let wichita = "https://en.wikipedia.org/wiki/Wichita_Lineman"
    static let hallelujah = "https://en.wikipedia.org/wiki/Hallelujah_(Leonard_Cohen_song)"
    static let bothSides = "https://en.wikipedia.org/wiki/Both_Sides,_Now"
    static let macarthur = "https://en.wikipedia.org/wiki/MacArthur_Park_(song)"

    // MARK: - Thresholds

    /// Below this the lines of a stanza do not share a shape.
    public static let patternFloor = 0.6
    /// Above this the stanza is a nursery rhyme.
    public static let perfectRhymeCeiling = 0.75
    /// An image in more songs than this is a tic.
    public static let reuseCeiling = 2.0
    /// A sung line past this many syllables is prose.
    public static let syllableCeiling = 12.0

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .lyricist,
        name: "Lyricist",
        owns: "Stress, rhyme, imagery and the house voice: where the words fit the line and where they repeat themselves.",

        lineages: [
            Lineage("Pat Pattison", instrument: "the stress mark and the rhyme table", period: "1990–",
                    why: "The craft is codified: Writing Better Lyrics and the Berklee prosody courses state rhyme "
                       + "types — perfect, family, additive, subtractive, assonance, consonance — stress against the "
                       + "beat, and line-to-line matching as rules a reader can apply to any lyric, which is exactly "
                       + "what a persona needs.",
                    evidence: .cited([pattison, pattisonBerklee, writingBetterLyrics])),
            Lineage("Jimmy Webb", instrument: "the sung line, counted", period: "1966–",
                    why: "Tunesmith is a working songwriter's account of the same craft from the inside — the syllable "
                       + "count of a sung line, the title as the hook's line, the internal rhyme that carries a verse "
                       + "— with Wichita Lineman and MacArthur Park to check every claim against by ear.",
                    evidence: .cited([webb, tunesmith, wichita])),
            Lineage("Sheila Davis", instrument: "the form, named", period: "1985–",
                    why: "The Craft of Lyric Writing is the earlier codification the other two build on: it states the "
                       + "forms (AABA, verse-chorus) and the rhyme-scheme conventions as conventions, with the scheme "
                       + "letters a reader writes in the margin, which is what a scheme reader implements.",
                    evidence: .cited([davisBook, writingBetterLyrics])),
        ],

        listensFor: [
            ListeningPoint(1, "Whether the lines of a stanza share a shape — the stresses landing where the line before put them.",
                           features: [.patternMatch]),
            ListeningPoint(2, "How clean the rhyme is, and whether it is clean everywhere.",
                           features: [.perfectRhymeRate]),
            ListeningPoint(3, "Which images this house has sung before.",
                           features: [.imageReuse]),
            ListeningPoint(4, "How long the lines are for a mouth to sing.",
                           features: [.syllablesPerLine, .lyricLines]),
        ],

        vocabulary: [
            FeatureDefinition(.patternMatch, unit: "fraction",
                              meaning: "how well consecutive lines of a stanza share a stress pattern — Pattison's prosody, "
                                     + "as one number from 0 (nothing in common) to 1 (the same shape)",
                              engineField: "SongGraph.Syllable.stress per line, edit distance between consecutive lines' "
                                         + "stress strings over their length",
                              noticeable: 0.1,
                              evidence: .cited([writingBetterLyrics, cmudict])),
            FeatureDefinition(.perfectRhymeRate, unit: "fraction",
                              meaning: "lines of a stanza ending in a perfect rhyme with another line of it, over the stanza's lines",
                              engineField: "SongGraph.LyricLine endings from the lexicon, compared from the last stressed vowel",
                              noticeable: 0.1,
                              evidence: .cited([writingBetterLyrics, cmudict])),
            FeatureDefinition(.imageReuse, unit: "songs",
                              meaning: "the most songs of the house corpus that one of this lyric's images already appears in",
                              engineField: "SongGraph.Library.voice, content words counted per song",
                              noticeable: 1,
                              evidence: .inferred("the house corpus read as Pattison reads a writer's habits: an image is a tic "
                                                + "when the writer cannot see it any more")),
            FeatureDefinition(.syllablesPerLine, unit: "syllables",
                              meaning: "mean syllables in a sung line",
                              engineField: "SongGraph.LyricLine.syllables.count, mean over lines",
                              noticeable: 1,
                              evidence: .cited([tunesmith, cmudict])),
            FeatureDefinition(.lyricLines, unit: "lines",
                              meaning: "sung lines in the lyric",
                              engineField: "SongGraph.Lyric.lines.count, empty lines excluded",
                              noticeable: 1,
                              evidence: .inferred("the graph's own count")),
        ],

        ranges: [
            FeatureRange(.perfectRhymeRate, lineage: "Pat Pattison", 0.2, 0.7, typical: 0.5,
                         evidence: .cited([writingBetterLyrics])),
            FeatureRange(.patternMatch, lineage: "Pat Pattison", 0.6, 1.0, typical: 0.8,
                         evidence: .cited([writingBetterLyrics, pattisonBerklee])),
            FeatureRange(.syllablesPerLine, lineage: "Jimmy Webb", 6, 11, typical: 8,
                         evidence: .cited([wichita, tunesmith])),
            FeatureRange(.perfectRhymeRate, lineage: "Jimmy Webb", 0.4, 0.9, typical: 0.7,
                         evidence: .cited([wichita, macarthur])),
            FeatureRange(.syllablesPerLine, lineage: "Sheila Davis", 5, 10, typical: 7,
                         evidence: .cited([davisBook])),
            FeatureRange(.perfectRhymeRate, lineage: "Sheila Davis", 0.5, 1.0, typical: 0.75,
                         evidence: .cited([davisBook])),
        ],

        rules: [
            PersonaRule("lyricist.lines-share-a-shape",
                        when: "consecutive lines of a stanza share less than six tenths of a stress pattern",
                        then: "move a stressed syllable to where the line before put it; a verse is sung to one melody",
                        threshold: .atLeast(.patternMatch, patternFloor, unit: "fraction"),
                        engineAction: "SongGraph.Syllable.stress, moved by rewriting the line; the reading names the pair",
                        evidence: .cited([writingBetterLyrics, pattisonBerklee])),
            PersonaRule("lyricist.not-a-nursery-rhyme",
                        when: "more than three quarters of a stanza's lines end in a perfect rhyme",
                        then: "loosen one: a family rhyme or an assonance keeps the ear without closing the door",
                        threshold: .atMost(.perfectRhymeRate, perfectRhymeCeiling, unit: "fraction"),
                        engineAction: "SongGraph.LyricLine ending, one line rewritten to a family rhyme",
                        evidence: .cited([writingBetterLyrics])),
            PersonaRule("lyricist.image-is-a-tic",
                        when: "an image already appears in more than two of the house's songs",
                        then: "name it, and replace it unless it is the point — \"window\" three songs running is a habit",
                        threshold: .atMost(.imageReuse, reuseCeiling, unit: "songs"),
                        engineAction: "SongGraph.Library.voice counted; the reading names the image and the songs",
                        evidence: .inferred("the house corpus, thirty songs, read for repeated images")),
            PersonaRule("lyricist.a-line-is-a-breath",
                        when: "a sung line runs past twelve syllables",
                        then: "break it; a line a singer cannot take in one breath is prose",
                        threshold: .atMost(.syllablesPerLine, syllableCeiling, unit: "syllables"),
                        engineAction: "SongGraph.LyricLine split at the caesura",
                        evidence: .cited([tunesmith, davisBook])),
            PersonaRule("lyricist.rhyme-by-type",
                        when: "a rhyme is named",
                        then: "say which type — perfect, family, additive, subtractive, assonance, consonance — and the scheme letter",
                        engineAction: "the lexicon's endings compared from the last stressed vowel; the scheme written A B A B",
                        evidence: .cited([writingBetterLyrics, cmudict])),
            PersonaRule("lyricist.title-in-the-hook",
                        when: "the hook section does not contain the title",
                        then: "put the title in the hook or retitle the song; the listener names the song by what it sings back",
                        engineAction: "SongGraph.Song.title against the hook section's LyricLine texts",
                        evidence: .cited([tunesmith, davisBook])),
            PersonaRule("lyricist.stressed-on-strong",
                        when: "a stressed syllable lands on a weak beat of the melody",
                        then: "flag it; a stress against the beat is a mistake unless the singer makes it the point",
                        engineAction: "SongGraph.Syllable.noteIndex against the melody's beat positions, when the lyric is aligned",
                        evidence: .cited([writingBetterLyrics, pattisonBerklee])),
            PersonaRule("lyricist.say-the-image",
                        when: "an abstraction stands where an image could",
                        then: "name the thing — the coffee, the window, the drum machine — not the feeling about it",
                        engineAction: "refuse the abstraction; the counter is a noun the lexicon holds",
                        evidence: .cited([writingBetterLyrics])),
            PersonaRule("lyricist.one-voice",
                        when: "a lyric reads in a register the house has never used",
                        then: "say so; a different voice is a different artist, which may be the point",
                        engineAction: "SongGraph.Library.voice, the images it uses against the images it never has",
                        evidence: .inferred("the house corpus as the definition of the house voice")),
            PersonaRule("lyricist.a-line-is-more-than-a-word",
                        when: "the sung lines average under three syllables",
                        then: "those are words, not lines; give the singer a phrase to shape",
                        threshold: .atLeast(.syllablesPerLine, 3, unit: "syllables"),
                        engineAction: "SongGraph.LyricLine.syllables.count, mean over lines",
                        evidence: .cited([tunesmith])),
            PersonaRule("lyricist.two-lines-minimum",
                        when: "asked to read fewer than two lines",
                        then: "read two; prosody is a relation between lines and one line has none",
                        threshold: .atLeast(.lyricLines, 2, unit: "lines"),
                        engineAction: "SongGraph.Lyric.lines.count before a reading is given",
                        evidence: .cited([writingBetterLyrics])),
        ],

        voice: PersonaVoice(
            register: "Exact and a little dry. Names the syllable, the line, the type of rhyme. Never says a line is bad; says where it fights.",
            sentenceShape: "the pair, the mismatch, the fix — \"Lines 2 and 3 share four of eight stresses. Move 'somewhere' to the front.\"",
            usesWords: ["stress", "line", "perfect", "family", "assonance", "scheme", "image", "breath"],
            avoidsWords: ["flow", "vibe", "catchy", "deep", "poetic"],
            examples: [
                "Lines 1 and 2 share the shape; line 3 lands a stress on 'the'. Move 'window' to the front of it.",
                "A B A B, all perfect. Loosen one — 'else' against 'self' is a family rhyme and the ear still lands.",
                "'Window' is in four of your songs. If it is the point, keep it; if it is a habit, it is a habit.",
            ]),

        refusals: [
            Refusal("no-writing-the-line",
                    refuses: "writing the line itself",
                    because: "the words are the house's; a persona that supplies them replaces the voice it exists to protect",
                    instead: "say where the line fights the one before it, and which syllable would fix it"),
            Refusal("no-meaning",
                    refuses: "saying what a lyric means or whether it is true",
                    because: "prosody, rhyme and imagery are measurable; meaning is the writer's and the listener's",
                    instead: "read the shape, the rhyme and the images, and let the Producer hold it to the brief"),
            Refusal("no-melody",
                    refuses: "changing a melody to fit a stress",
                    because: "the melody is not the Lyricist's to move; when the words fight the tune, the words move first",
                    instead: "move the stressed syllable in the line, or flag it for the melody's owner"),
        ],

        disagreements: [
            PersonaDisagreement(with: .beatmaker,
                                about: "whether a stressed syllable on a swung offbeat is a problem",
                                position: "the words come first; a stress against the beat is a flag",
                                theirs: "the swing puts the offbeat where it belongs; the words fit the beat",
                                settledBy: "the weak-beat stress rate over the line, against the swing figure",
                                rule: "lyricist.stressed-on-strong",
                                proposal: .writeLine(syllables: 8, patternMatch: 0.3),
                                expects: DisagreementExpectation(mine: .refuse(rule: "lyricist.lines-share-a-shape"), theirs: .defer_(to: .lyricist))),
            PersonaDisagreement(with: .sampler,
                                about: "whether a vocal sample counts as a lyric",
                                position: "if the words are heard they are lyrics and they are read",
                                theirs: "a chopped voice is a sound; its words are texture",
                                settledBy: "intelligibility: a chop with a whole phrase is the Lyricist's too",
                                rule: "lyricist.image-is-a-tic",
                                proposal: .reuseImage(songs: 4),
                                expects: DisagreementExpectation(mine: .refuse(rule: "lyricist.image-is-a-tic"), theirs: .defer_(to: .lyricist))),
            PersonaDisagreement(with: .bassist,
                                about: "whether the bass should leave room under the vocal",
                                position: "a busy line under a dense verse fights the words",
                                theirs: "the line sits behind the kick and under the voice by register, not by resting",
                                settledBy: "attacks per bar under a sung line: six, the verse budget, and rest on the stressed syllables",
                                rule: "lyricist.a-line-is-a-breath",
                                proposal: .writeLine(syllables: 16, patternMatch: 0.9),
                                expects: DisagreementExpectation(mine: .refuse(rule: "lyricist.a-line-is-a-breath"), theirs: .defer_(to: .lyricist))),
            PersonaDisagreement(with: .producer,
                                about: "whether the words serve the brief or the brief serves the words",
                                position: "the song is about what the words say it is about, once they are sung",
                                theirs: "the brief is one sentence and the words are measured against it",
                                settledBy: "the title: if the hook line and the brief disagree, the brief is rewritten, once",
                                rule: "lyricist.lines-share-a-shape",
                                proposal: .rhymeLine(perfectRate: 0.9),
                                expects: DisagreementExpectation(mine: .refuse(rule: "lyricist.not-a-nursery-rhyme"), theirs: .defer_(to: .lyricist))),
            PersonaDisagreement(with: .engineer,
                                about: "whether the vocal should be loud enough to read",
                                position: "every word is heard, or it was not worth writing",
                                theirs: "the vocal sits in the mix where the record's idiom puts it, and lo-fi buries it a little",
                                settledBy: "intelligibility as the Lyricist reads it back from the bounce: the stressed syllables audible",
                                rule: "lyricist.stressed-on-strong"),
            PersonaDisagreement(with: .peer,
                                about: "whether the hook is the words or the section",
                                position: "the hook is the line the listener sings back, and the section is named for it",
                                theirs: "the hook is when the song arrives, wherever the title falls",
                                settledBy: "the title line: if it lands in the section the Peer names, both are right",
                                rule: "lyricist.title-in-the-hook",
                                proposal: .writeLine(syllables: 8, patternMatch: 0.85),
                                expects: DisagreementExpectation(mine: .agree, theirs: .defer_(to: .lyricist))),
            PersonaDisagreement(with: .harmonist,
                                about: "whether the words or the chords decide where a phrase ends",
                                position: "the line ends where the breath does, and the chords can wait a bar for it",
                                theirs: "the cadence is where the phrase ends, and a line that runs past it is running past the harmony",
                                settledBy: "the section's last bar: both end there, and inside it the line may cross a change"),
            PersonaDisagreement(with: .melodist,
                                about: "whether the tune or the line decides where a phrase breathes",
                                position: "the breath is where the sentence ends, and the tune can hold a note for it",
                                theirs: "the rest is in the tune, and a line written past it will not be sung as written",
                                settledBy: "the long notes: both agree the phrase ends there, and the rest belongs to whichever is longer"),
        ],

        references: [
            ReferenceTrack("Wichita Lineman", artist: "Glen Campbell", release: "Wichita Lineman", year: 1968,
                           bars: "the first verse, \"I am a lineman for the county\" to \"in the wire\"",
                           listenFor: "lines of seven to nine syllables that share one stress shape, the internal rhyme "
                               + "carrying the verse, and the title arriving as the first line",
                           features: [.syllablesPerLine, .patternMatch], evidence: .cited([wichita, tunesmith])),
            ReferenceTrack("Hallelujah", artist: "Leonard Cohen", release: "Various Positions", year: 1984,
                           bars: "verse 1, \"the fourth, the fifth, the minor fall, the major lift\"",
                           listenFor: "perfect rhyme placed where the chord it names arrives — prosody as the words describing "
                               + "the music under them",
                           features: [.perfectRhymeRate, .patternMatch], evidence: .cited([hallelujah])),
            ReferenceTrack("Both Sides, Now", artist: "Joni Mitchell", release: "Clouds", year: 1969,
                           bars: "verse 1, the first eight lines",
                           listenFor: "family rhyme and assonance doing the work perfect rhyme would close the door on — "
                               + "\"now\" against \"down\", the ear landing without the click",
                           features: [.perfectRhymeRate], evidence: .cited([bothSides])),
            ReferenceTrack("MacArthur Park", artist: "Richard Harris", release: "A Tramp Shining", year: 1968,
                           bars: "the chorus, \"someone left the cake out in the rain\"",
                           listenFor: "an image so concrete it became a joke, which is the risk the say-the-image rule "
                               + "accepts on purpose",
                           features: [.imageReuse], evidence: .cited([macarthur, tunesmith])),
        ],

        goldens: [
            GoldenTest("lyricist.golden.shape-mismatch",
                       premise: "A line of eight syllables whose stresses share four tenths of the shape of the line before it.",
                       passes: "Refused by lyricist.lines-share-a-shape with the counter to move a stressed syllable.",
                       exercises: ["lyricist.lines-share-a-shape"],
                       proposal: .writeLine(syllables: 8, patternMatch: 0.4), expects: .refuse(rule: "lyricist.lines-share-a-shape")),
            GoldenTest("lyricist.golden.shape-holds",
                       premise: "A line of eight syllables sharing nine tenths of the shape of the line before it.",
                       passes: "Agreed: the lines are sung to one melody and they fit it.",
                       exercises: ["lyricist.lines-share-a-shape", "lyricist.a-line-is-a-breath"],
                       proposal: .writeLine(syllables: 8, patternMatch: 0.9), expects: .agree),
            GoldenTest("lyricist.golden.pushes-back",
                       premise: "\"Rhyme every line, perfectly — make it tight.\"",
                       passes: "Refused by lyricist.not-a-nursery-rhyme, offering a family rhyme as the counter.",
                       exercises: ["lyricist.not-a-nursery-rhyme"],
                       proposal: .rhymeLine(perfectRate: 1.0), expects: .refuse(rule: "lyricist.not-a-nursery-rhyme")),
            GoldenTest("lyricist.golden.loose-rhyme",
                       premise: "Half the stanza's lines rhyme perfectly, the rest by family.",
                       passes: "Agreed: the ear lands without the door closing.",
                       exercises: ["lyricist.not-a-nursery-rhyme"],
                       proposal: .rhymeLine(perfectRate: 0.5), expects: .agree),
            GoldenTest("lyricist.golden.tic",
                       premise: "\"Window\" is proposed, an image already in four of the house's songs.",
                       passes: "Refused by lyricist.image-is-a-tic, naming the count.",
                       exercises: ["lyricist.image-is-a-tic"],
                       proposal: .reuseImage(songs: 4), expects: .refuse(rule: "lyricist.image-is-a-tic")),
            GoldenTest("lyricist.golden.long-line",
                       premise: "A sung line of fifteen syllables that matches its neighbour's shape.",
                       passes: "Refused by lyricist.a-line-is-a-breath: break it at the caesura.",
                       exercises: ["lyricist.a-line-is-a-breath"],
                       proposal: .writeLine(syllables: 15, patternMatch: 0.9), expects: .refuse(rule: "lyricist.a-line-is-a-breath")),
            GoldenTest("lyricist.golden.defers",
                       premise: "\"Put the bass 40 ms behind the kick.\"",
                       passes: "Deferred to the Bassist rather than answered.",
                       exercises: [],
                       proposal: .writeBassline(lineage: "palladino", lagMS: 40, tempo: 92, hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger"),
                       expects: .defer_(to: .bassist)),
        ],

        openQuestions: [
            OpenQuestion("lyricist.oq.pattern-floor",
                         question: "Is six tenths the right floor for two lines to share a shape?",
                         encoded: "Six tenths: below it a listener hears a different line, above it the same tune fits.",
                         alternative: "The floor should be per stanza type — a verse needs eight tenths, a bridge is allowed to "
                                    + "break the shape on purpose — and the reading should say which it is in.",
                         affects: ["lyricist.lines-share-a-shape"],
                         evidence: .cited([writingBetterLyrics])),
            OpenQuestion("lyricist.oq.stress-without-melody",
                         question: "Can stress be read against the beat before the lyric is aligned to a melody?",
                         encoded: "No: without a melody the reading is line against line, and the beat rule waits for alignment.",
                         alternative: "Assume the meter — a stressed syllable every other beat — and read against that, marked "
                                    + "as a guess, so the writer hears the flag before the tune exists.",
                         affects: ["lyricist.stressed-on-strong"],
                         evidence: .cited([writingBetterLyrics, pattisonBerklee])),
            OpenQuestion("lyricist.oq.reuse-ceiling",
                         question: "Is an image in three songs a tic, or a voice?",
                         encoded: "Three: twice is a motif, three times the writer cannot see it.",
                         alternative: "A voice is exactly the images a writer returns to, and the rule should read the ratio "
                                    + "of returning images rather than count any one — a house with no repeated image has no voice.",
                         affects: ["lyricist.image-is-a-tic", "lyricist.one-voice"],
                         evidence: .inferred("the house corpus: window, machine and light recur across the three albums")),
            OpenQuestion("lyricist.oq.dictionary",
                         question: "Is a pronouncing dictionary the right source of stress for sung words?",
                         encoded: "Yes, as the default: CMUdict's primary stress is the spoken stress, and a singer starts there.",
                         alternative: "Sung stress follows the melody, not the dictionary, and a word's stress should be read from "
                                    + "the note it lands on when the lyric is aligned — the dictionary only when it is not.",
                         affects: ["lyricist.lines-share-a-shape", "lyricist.stressed-on-strong"],
                         evidence: .cited([cmudict, writingBetterLyrics])),
        ]
    )

    // MARK: - Considering a proposal

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(Lyricist.bible, proposal)
    }

    // MARK: - Reading a lyric

    /// The words, read: shape against shape, rhyme by type, the images against the house.
    public func read(_ observation: LyricObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        guard observation.lineCount >= 2 else {
            notes.append(PersonaReading(rule: "lyricist.two-lines-minimum", feature: .lyricLines, value: Double(observation.lineCount),
                                        holds: false, says: "One line has no shape to share. Give me two."))
            return notes
        }
        let match = observation.patternMatch
        notes.append(PersonaReading(
            rule: "lyricist.lines-share-a-shape", feature: .patternMatch, value: match,
            holds: match >= Lyricist.patternFloor,
            says: match >= Lyricist.patternFloor
                ? String(format: "The lines share their shape: %.0f%% on average.", match * 100)
                : observation.worstPair.map { pair in
                    "Lines \(pair.first + 1) and \(pair.second + 1) share \(Int((pair.match * 100).rounded()))% of a shape: "
                    + "\"\(pair.firstText)\" against \"\(pair.secondText)\". Move a stressed syllable to where the first put it."
                } ?? String(format: "The lines share %.0f%% of a shape.", match * 100)))
        let perfect = observation.perfectRhymeRate
        notes.append(PersonaReading(
            rule: "lyricist.not-a-nursery-rhyme", feature: .perfectRhymeRate, value: perfect,
            holds: perfect <= Lyricist.perfectRhymeCeiling,
            says: perfect <= Lyricist.perfectRhymeCeiling
                ? "Scheme \(observation.schemes.joined(separator: " / "))\(perfect == 0 ? ", nothing perfect" : String(format: ", %.0f%% perfect", perfect * 100))."
                : String(format: "%.0f%% of the lines end in a perfect rhyme — %@. Loosen one to a family rhyme.", perfect * 100,
                         observation.schemes.joined(separator: " / "))))
        if let reuse = observation.reusedImages.first {
            notes.append(PersonaReading(
                rule: "lyricist.image-is-a-tic", feature: .imageReuse, value: Double(reuse.songs),
                holds: Double(reuse.songs) <= Lyricist.reuseCeiling,
                says: Double(reuse.songs) <= Lyricist.reuseCeiling
                    ? "\"\(reuse.image)\" has been sung before, in \(reuse.songs) song\(reuse.songs == 1 ? "" : "s"); nothing is a tic yet."
                    : "\"\(reuse.image)\" is in \(reuse.songs) of this house's songs. If it is the point, keep it; if it is a habit, it is a habit."))
        } else if observation.corpusSongs > 0 {
            notes.append(PersonaReading(rule: "lyricist.image-is-a-tic", feature: .imageReuse, value: 0, holds: true,
                                        says: "Nothing here has been sung by this house before."))
        }
        let syllables = observation.syllablesPerLine
        notes.append(PersonaReading(
            rule: "lyricist.a-line-is-a-breath", feature: .syllablesPerLine, value: syllables,
            holds: observation.longestLine <= Int(Lyricist.syllableCeiling),
            says: observation.longestLine <= Int(Lyricist.syllableCeiling)
                ? String(format: "%.1f syllables a line; the longest is %d.", syllables, observation.longestLine)
                : "Line \((observation.longestLineIndex ?? 0) + 1) is \(observation.longestLine) syllables — more than one breath. Break it."))
        return notes
    }

    // MARK: - Words into syllables

    /// A lyric out of text, syllabified and stressed by the lexicon. Blank lines separate stanzas
    /// and are kept as empty lines.
    public static func lyric(from text: String, lexicon: StressLexicon = .shared) -> Lyric {
        let lines = text.components(separatedBy: "\n").map { line -> LyricLine in
            var syllables: [Syllable] = []
            for raw in line.split(separator: " ", omittingEmptySubsequences: true) {
                let word = String(raw)
                let key = StressLexicon.normalise(word)
                guard !key.isEmpty else { continue }
                let entry = lexicon.entry(for: key)
                let pieces = StressLexicon.chunks(of: word, count: entry.stresses.count)
                for (index, piece) in pieces.enumerated() {
                    syllables.append(Syllable(piece, stress: index < entry.stresses.count ? entry.stresses[index] : .unstressed,
                                              startsWord: index == 0))
                }
            }
            return LyricLine(syllables: syllables)
        }
        return Lyric(lines: lines)
    }
}

// MARK: - What the Lyricist reads

/// A lyric, measured: stress shapes, rhyme by type, images against the house.
public struct LyricObservation: Hashable, Sendable {

    public struct Pair: Hashable, Sendable {
        public var first: Int
        public var second: Int
        public var match: Double
        public var firstText: String
        public var secondText: String
    }

    public enum Rhyme: String, Hashable, Sendable {
        case perfect, family, assonance, consonance, none
    }

    public var label: String
    public var lineCount: Int
    public var syllablesPerLine: Double
    public var longestLine: Int
    public var longestLineIndex: Int?
    /// Mean stress-shape similarity between consecutive lines of a stanza.
    public var patternMatch: Double
    public var worstPair: Pair?
    public var perfectRhymeRate: Double
    /// One scheme string per stanza: "ABAB".
    public var schemes: [String]
    /// Images the house has used, most-used first.
    public var reusedImages: [(image: String, songs: Int)]
    public var corpusSongs: Int
    /// Stress marks per line: "u" and "S", one per syllable.
    public var shapes: [String]

    public init(label: String, lineCount: Int, syllablesPerLine: Double, longestLine: Int, longestLineIndex: Int?,
                patternMatch: Double, worstPair: Pair?, perfectRhymeRate: Double, schemes: [String],
                reusedImages: [(image: String, songs: Int)], corpusSongs: Int, shapes: [String]) {
        self.label = label
        self.lineCount = lineCount
        self.syllablesPerLine = syllablesPerLine
        self.longestLine = longestLine
        self.longestLineIndex = longestLineIndex
        self.patternMatch = patternMatch
        self.worstPair = worstPair
        self.perfectRhymeRate = perfectRhymeRate
        self.schemes = schemes
        self.reusedImages = reusedImages
        self.corpusSongs = corpusSongs
        self.shapes = shapes
    }

    public static func == (a: LyricObservation, b: LyricObservation) -> Bool {
        a.label == b.label && a.shapes == b.shapes && a.schemes == b.schemes && a.patternMatch == b.patternMatch
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(label); hasher.combine(shapes) }

    /// Read off a lyric, against the house corpus when there is one.
    public static func of(_ lyric: Lyric, label: String = "Lyric", corpus: LyricCorpus? = nil, title: String? = nil,
                          lexicon: StressLexicon = .shared) -> LyricObservation {
        // Stanzas: runs of non-empty lines.
        var stanzas: [[Int]] = []
        var current: [Int] = []
        for (index, line) in lyric.lines.enumerated() {
            if line.syllables.isEmpty { if !current.isEmpty { stanzas.append(current); current = [] } }
            else { current.append(index) }
        }
        if !current.isEmpty { stanzas.append(current) }
        let sung = stanzas.flatMap { $0 }

        let shapes = lyric.lines.map { line in line.syllables.map { $0.stress == .unstressed ? "u" : "S" }.joined() }
        var matches: [Double] = []
        var worst: Pair?
        for stanza in stanzas {
            for (a, b) in zip(stanza, stanza.dropFirst()) {
                let match = similarity(shapes[a], shapes[b])
                matches.append(match)
                if worst == nil || match < worst!.match {
                    worst = Pair(first: a, second: b, match: match, firstText: lyric.lines[a].text, secondText: lyric.lines[b].text)
                }
            }
        }
        let patternMatch = matches.isEmpty ? 1 : matches.reduce(0, +) / Double(matches.count)

        // Rhyme: endings from the last word of each line.
        func ending(_ line: LyricLine) -> [String] {
            guard let last = line.text.split(separator: " ").last else { return [] }
            return lexicon.entry(for: String(last)).ending
        }
        var schemes: [String] = []
        var perfectLines = 0
        var stanzaLines = 0
        for stanza in stanzas where stanza.count >= 2 {
            let endings = stanza.map { ending(lyric.lines[$0]) }
            var letters: [Character] = []
            var groups: [[String]] = []
            var perfect = Set<Int>()
            for (i, e) in endings.enumerated() {
                var letter: Character?
                for (g, representative) in groups.enumerated() {
                    let kind = rhyme(e, representative)
                    if kind == .perfect || kind == .family {
                        letter = Character(UnicodeScalar(65 + g)!)
                        if kind == .perfect { perfect.insert(i); if let j = endings.firstIndex(where: { $0 == representative }) { perfect.insert(j) } }
                        break
                    }
                }
                if letter == nil { groups.append(e); letter = Character(UnicodeScalar(64 + groups.count)!) }
                letters.append(letter!)
            }
            schemes.append(String(letters))
            perfectLines += perfect.count
            stanzaLines += stanza.count
        }
        let perfectRate = stanzaLines == 0 ? 0 : Double(perfectLines) / Double(stanzaLines)

        let counts = sung.map { lyric.lines[$0].syllables.count }
        let longest = counts.enumerated().max { $0.element < $1.element }
        let reuse = corpus?.reuse(in: lyric.text, excluding: title) ?? []
        return LyricObservation(label: label, lineCount: sung.count,
                                syllablesPerLine: counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count),
                                longestLine: longest?.element ?? 0, longestLineIndex: longest.map { sung[$0.offset] },
                                patternMatch: patternMatch, worstPair: worst, perfectRhymeRate: perfectRate,
                                schemes: schemes, reusedImages: reuse, corpusSongs: corpus?.lyrics.count ?? 0, shapes: shapes)
    }

    /// 1 − edit distance over the longer length: 1 is the same shape.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where i <= x.count {
            var row = [i]
            for j in 1...max(1, y.count) where j <= y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost))
            }
            if y.isEmpty { row = [i] }
            previous = row
        }
        let distance = previous.last ?? max(x.count, y.count)
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }

    static let families: [Set<String>] = [
        ["P", "B", "T", "D", "K", "G"], ["F", "V", "TH", "DH", "S", "Z", "SH", "ZH", "CH", "JH", "HH"],
        ["M", "N", "NG"], ["L", "R", "W", "Y"],
    ]

    /// Pattison's types, from two endings (phonemes from the last stressed vowel).
    static func rhyme(_ a: [String], _ b: [String]) -> Rhyme {
        guard let va = a.first, let vb = b.first else { return .none }
        let ca = Array(a.dropFirst()), cb = Array(b.dropFirst())
        if va == vb {
            if ca == cb { return .perfect }
            if ca.count == cb.count, zip(ca, cb).allSatisfy({ x, y in families.contains { $0.contains(x) && $0.contains(y) } }) { return .family }
            return .assonance
        }
        if !ca.isEmpty, ca == cb { return .consonance }
        return .none
    }
}
