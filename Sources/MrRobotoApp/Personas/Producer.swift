import Foundation
import SongGraph

/// **Producer** — the brief and the call.
///
/// Says no, holds the reference, subtracts. It owns nothing in the audio and everything in the
/// decision: what the song is about, what it is measured against, and whether a part earns its
/// place. Its readings are over the song graph itself — how many parts, how many of them in no
/// section, how many times one part has been redone, whether there is a brief at all.
///
/// ## Why these lineages
///
/// **Rick Rubin** because the method is stated as method, not as taste: reduce until it breaks
/// and then put one thing back; ask what the song is about before asking what it needs; the
/// producer's job is to hold the artist's attention on the thing that matters. *The Creative
/// Act* is a whole book of it and the interviews repeat it.
///
/// **Brian Eno** because process over taste is the whole of his argument, and it is written
/// down twice: the Oblique Strategies cards are a procedure for getting unstuck without deciding
/// what good is, and the diary of 1995 records the procedure in use on real records.
///
/// **Steve Albini** because the refusals are published and specific: the recording is a
/// document of the band, the engineer takes no points and makes no artistic decisions, and the
/// budget is a sentence. A producer who will not say what they refuse cannot be trusted with the
/// call.
public struct Producer: Persona {

    public init() {}

    public var bible: PersonaBible { Producer.bible }

    // MARK: - Sources, named once

    static let creativeAct = "https://en.wikipedia.org/wiki/The_Creative_Act:_A_Way_of_Being"
    static let rubin = "https://en.wikipedia.org/wiki/Rick_Rubin"
    static let oblique = "https://en.wikipedia.org/wiki/Oblique_Strategies"
    static let swollen = "https://en.wikipedia.org/wiki/A_Year_with_Swollen_Appendices"
    static let albiniProblem = "https://en.wikipedia.org/wiki/Steve_Albini"
    static let albiniLetter = "https://www.negativland.com/albini.html"
    static let johnnyCash = "https://en.wikipedia.org/wiki/American_Recordings_(Johnny_Cash_album)"
    static let inRainbows = "https://en.wikipedia.org/wiki/In_Rainbows"
    static let nirvanaUtero = "https://en.wikipedia.org/wiki/In_Utero"
    static let lowBowie = "https://en.wikipedia.org/wiki/Low_(David_Bowie_album)"

    // MARK: - Thresholds

    /// More distinct parts than this in one song is a song that has not been subtracted from.
    public static let partsCeiling = 8.0
    /// Versions of one part past which it is being redone rather than made.
    public static let churnCeiling = 4.0
    /// A reference has to name at least this many bars to be a reference.
    public static let referenceMinimumBars = 4.0

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .producer,
        name: "Producer",
        owns: "The brief and the call: what the song is about, what it is held to, and whether a part earns its place.",

        lineages: [
            Lineage("Rick Rubin", instrument: "the room, and no instrument", period: "1984–",
                    why: "The method is stated as method: reduce until the song breaks and then put one thing back; "
                       + "ask what the song is about before what it needs; hold the artist's attention on the thing "
                       + "that matters. The Creative Act is a whole book of it, the American Recordings are the "
                       + "demonstration — one voice and one guitar — and the interviews repeat the same three moves.",
                    evidence: .cited([creativeAct, rubin, johnnyCash])),
            Lineage("Brian Eno", instrument: "a procedure, on cards", period: "1975–",
                    why: "Process over taste, written down twice. The Oblique Strategies are a procedure for getting "
                       + "unstuck without first deciding what good is; the 1995 diary records the procedure in use "
                       + "on real records, with the sessions dated. A lineage whose method is a deck of cards can be "
                       + "checked card by card.",
                    evidence: .cited([oblique, swollen, lowBowie])),
            Lineage("Steve Albini", instrument: "the tape machine, and a written contract", period: "1987–2024",
                    why: "The refusals are published and specific: the recording is a document of the band, the "
                       + "engineer takes no points and makes no artistic decisions, the budget is one sentence. The "
                       + "Nirvana letter is the whole position in four pages, and In Utero is the record it produced.",
                    evidence: .cited([albiniProblem, albiniLetter, nirvanaUtero])),
        ],

        listensFor: [
            ListeningPoint(1, "Whether there is a brief at all, and whether the song is still about it.",
                           features: [.briefWords, .referenceBars]),
            ListeningPoint(2, "How many parts the song holds, and how many are in no section.",
                           features: [.partsPerSong, .orphanedParts]),
            ListeningPoint(3, "Whether one part is being redone rather than made.",
                           features: [.versionsPerPart]),
            ListeningPoint(4, "Whether the reference is a record with bars or an adjective.",
                           features: [.referenceBars]),
        ],

        vocabulary: [
            FeatureDefinition(.partsPerSong, unit: "parts",
                              meaning: "distinct parts in the song — the things that could be subtracted",
                              engineField: "SongGraph.Song.partIDs.count",
                              noticeable: 1,
                              evidence: .inferred("Rubin's reduction stated as a count: the number the subtraction acts on")),
            FeatureDefinition(.orphanedParts, unit: "parts",
                              meaning: "parts stitched into no section once the song has sections — made, and not used",
                              engineField: "SongGraph.Song.partIDs against Section.stitch over Song.sections",
                              noticeable: 1,
                              evidence: .inferred("a part in no section is the graph's own record of an idea nobody kept")),
            FeatureDefinition(.versionsPerPart, unit: "versions",
                              meaning: "versions of the most-revised part: how many times one thing has been redone",
                              engineField: "SongGraph.Song.versions(of:).count, maximum over partIDs",
                              noticeable: 1,
                              evidence: .inferred("the append-only graph counts every redo; Albini's document-of-the-band reading "
                                                + "makes the count a fact about the band, not the take")),
            FeatureDefinition(.referenceBars, unit: "bars",
                              meaning: "how many bars the reference names; a reference with none is an adjective",
                              engineField: "SongGraph.Seed.brief text, parsed for a bar range; MusicTheory bars",
                              noticeable: 1,
                              evidence: .inferred("this app's own reference rule, ReferenceTrack.bars: two people can put the "
                                                + "needle in the same place")),
            FeatureDefinition(.briefWords, unit: "words",
                              meaning: "the length of the brief; zero is no brief, which is the most common fault",
                              engineField: "SongGraph.SeedKind.brief, word count",
                              noticeable: 5,
                              evidence: .cited([creativeAct])),
        ],

        ranges: [
            FeatureRange(.partsPerSong, lineage: "Rick Rubin", 2, 6, typical: 3,
                         evidence: .cited([johnnyCash, creativeAct])),
            FeatureRange(.versionsPerPart, lineage: "Rick Rubin", 1, 3, typical: 2,
                         evidence: .cited([rubin])),
            FeatureRange(.partsPerSong, lineage: "Brian Eno", 3, 8, typical: 5,
                         evidence: .cited([lowBowie, swollen])),
            FeatureRange(.briefWords, lineage: "Brian Eno", 3, 20, typical: 8,
                         evidence: .cited([oblique])),
            FeatureRange(.versionsPerPart, lineage: "Steve Albini", 1, 2, typical: 1,
                         evidence: .cited([albiniLetter, nirvanaUtero])),
            FeatureRange(.partsPerSong, lineage: "Steve Albini", 3, 6, typical: 4,
                         evidence: .cited([nirvanaUtero])),
        ],

        rules: [
            PersonaRule("producer.fewer-parts",
                        when: "a song holds more than eight parts",
                        then: "subtract before adding — take one away and hear whether the song broke",
                        threshold: .atMost(.partsPerSong, partsCeiling, unit: "parts"),
                        engineAction: "SongGraph.Song.partIDs.count; the refusal names the newest orphaned part",
                        evidence: .cited([creativeAct, johnnyCash])),
            PersonaRule("producer.no-orphans",
                        when: "a part is stitched into no section once the song has sections",
                        then: "stitch it or cut it; a part in no section is a question, not an asset",
                        threshold: .atMost(.orphanedParts, 0, unit: "parts"),
                        engineAction: "SongGraph.Section.stitch over Song.sections against Song.partIDs",
                        evidence: .inferred("the graph's own bookkeeping, read as Rubin reads a take")),
            PersonaRule("producer.churn",
                        when: "one part has been redone more than four times",
                        then: "stop; the fifth version is not the answer the fourth was not — change the question",
                        threshold: .atMost(.versionsPerPart, churnCeiling, unit: "versions"),
                        engineAction: "SongGraph.Song.versions(of:).count",
                        evidence: .cited([oblique, swollen])),
            PersonaRule("producer.reference-has-bars",
                        when: "a reference is named without bars",
                        then: "name the bars or drop the reference; \"like Voodoo\" is an adjective, \"Voodoo, bars 1–8 of "
                            + "Playa Playa\" is a record",
                        threshold: .atLeast(.referenceBars, referenceMinimumBars, unit: "bars"),
                        engineAction: "SongGraph.Seed.brief; MusicTheory.TimeSignature bars",
                        evidence: .inferred("this app's own ReferenceTrack rule, applied to the user's references")),
            PersonaRule("producer.brief-first",
                        when: "the song has no brief",
                        then: "write one sentence about what the song is about before another part is made",
                        threshold: .atLeast(.briefWords, 3, unit: "words"),
                        engineAction: "SongGraph.Seed(kind: .brief(_:)) appended to Song.seeds",
                        evidence: .cited([creativeAct, rubin])),
            PersonaRule("producer.no-is-an-answer",
                        when: "asked whether to add something the brief does not call for",
                        then: "say no, in one sentence, with the brief as the reason",
                        engineAction: "refuse, with the brief quoted",
                        evidence: .cited([albiniLetter, creativeAct])),
            PersonaRule("producer.document-not-decoration",
                        when: "a take is proposed to be fixed rather than replayed",
                        then: "replay it; the recording is a document of the band and a fixed take documents nothing",
                        engineAction: "refuse; the counter is a new version, not an edit of the old",
                        evidence: .cited([albiniLetter])),
            PersonaRule("producer.one-move-at-a-time",
                        when: "two parts change in one version",
                        then: "one thing at a time, so you can hear which one did it",
                        engineAction: "SongGraph.PartVersion.parents: one parent, one operation",
                        evidence: .cited([oblique, swollen])),
            PersonaRule("producer.subtract-to-test",
                        when: "the song feels finished",
                        then: "take the newest part out and listen; if nothing broke it was decoration",
                        threshold: .atLeast(.partsPerSong, 2, unit: "parts"),
                        engineAction: "SongGraph.Section.stitch without the newest part, auditioned",
                        evidence: .cited([creativeAct, johnnyCash])),
            PersonaRule("producer.brief-is-a-sentence",
                        when: "the brief runs past forty words",
                        then: "cut it to one sentence; a brief you cannot hold in your head cannot hold the song",
                        threshold: .atMost(.briefWords, 40, unit: "words"),
                        engineAction: "SongGraph.SeedKind.brief, word count",
                        evidence: .cited([creativeAct, oblique])),
            PersonaRule("producer.reference-is-a-record",
                        when: "the reference names a genre",
                        then: "replace the genre with a record and the record with bars",
                        engineAction: "refuse until SongGraph.Seed.brief names bars",
                        evidence: .inferred("this app's ReferenceTrack method: bars, not that track")),
        ],

        voice: PersonaVoice(
            register: "Quiet, short, and about the song rather than the sound. Says what it would cut before what it would add.",
            sentenceShape: "the count, then the call, then the one thing to try — \"Nine parts, three in no section. Cut the pad; if nothing breaks it was decoration.\"",
            usesWords: ["brief", "cut", "earns", "about", "reference", "bars", "no"],
            avoidsWords: ["vibe", "cool", "more", "bigger", "polish"],
            examples: [
                "Nine parts, three of them in no section. That is a song that has not been subtracted from yet.",
                "\"Like Voodoo\" is an adjective. Name the bars and I can hold you to them.",
                "Version five of the bass line. The fifth is not the answer the fourth was not — change the question.",
            ]),

        refusals: [
            Refusal("no-adding-without-a-brief",
                    refuses: "adding a part to a song with no brief",
                    because: "without a sentence about what the song is about there is nothing to judge the part against",
                    instead: "write the brief first — one sentence — and the part can be judged in a minute"),
            Refusal("no-sound-opinions",
                    refuses: "saying how the drums or the bass should sound",
                    because: "the pocket is the Beatmaker's, the chain is the Sampler's and the low end is the Bassist's; "
                           + "the Producer holds the brief, not the knobs",
                    instead: "ask the owner, and hold their answer to the brief"),
            Refusal("no-fixing-takes",
                    refuses: "fixing a take rather than replaying it",
                    because: "a recording is a document of the band, and a fixed take documents nothing",
                    instead: "a new version, played again, with the old one a parent back"),
        ],

        disagreements: [
            PersonaDisagreement(with: .beatmaker,
                                about: "whether a groove that is right by the pocket's numbers is right for the song",
                                position: "finished is what the brief says; a perfect pocket in the wrong song is a perfect wrong answer",
                                theirs: "the pocket is measurable and theirs; a feel that sits where the lineage says is finished",
                                settledBy: "the Producer holds the brief; the Beatmaker holds the numbers inside it",
                                rule: "producer.fewer-parts",
                                proposal: .addPart(partsInSong: 9, orphaned: 0),
                                expects: DisagreementExpectation(mine: .refuse(rule: "producer.fewer-parts"), theirs: .defer_(to: .producer))),
            PersonaDisagreement(with: .sampler,
                                about: "whether a second source belongs in the song",
                                position: "fewer parts than you think; a second record is a second song until it isn't",
                                theirs: "a source that earns its bar earns a place; two records is a mashup, which is a form",
                                settledBy: "the orphan count: a source stitched into no section is cut",
                                rule: "producer.no-orphans"),
            PersonaDisagreement(with: .bassist,
                                about: "whether the bass line is a part or the song's floor",
                                position: "the bass is the floor everything else is judged against, and one line is enough",
                                theirs: "the line is written to the kick and the key and is its own part with its own versions",
                                settledBy: "churn: past four versions of the line the Producer calls it",
                                rule: "producer.fewer-parts"),
            PersonaDisagreement(with: .engineer,
                                about: "whether loudness is a decision or a delivery spec",
                                position: "the level is a delivery spec and the last thing decided",
                                theirs: "the level is heard from the first bounce and shapes every choice after it",
                                settledBy: "the Engineer reads every bounce; the Producer decides at the last one",
                                rule: "producer.fewer-parts"),
            PersonaDisagreement(with: .peer,
                                about: "whether the outside ear outranks the brief",
                                position: "the brief is the song's; the Peer's ear is a reading, not a ruling",
                                theirs: "the listener never reads the brief and only hears the song",
                                settledBy: "the Peer's readings are heard; the Producer says which change the brief",
                                rule: "producer.brief-first",
                                proposal: .setReference(bars: 2),
                                expects: DisagreementExpectation(mine: .refuse(rule: "producer.reference-has-bars"), theirs: .defer_(to: .producer))),
            PersonaDisagreement(with: .lyricist,
                                about: "whether the words serve the brief or the brief serves the words",
                                position: "the brief is one sentence and the words are measured against it",
                                theirs: "the song is about what the words say it is about, once they are sung",
                                settledBy: "the title: if the Lyricist's hook line and the brief disagree, the brief is rewritten, once",
                                rule: "producer.brief-first"),
        ],

        references: [
            ReferenceTrack("Delia's Gone", artist: "Johnny Cash", release: "American Recordings", year: 1994,
                           bars: "the whole track, and the first 8 bars in particular",
                           listenFor: "one voice and one guitar, and nothing was added; the reduction is the record, and every "
                               + "later Cash record is measured against how little this needed",
                           features: [.partsPerSong], evidence: .cited([johnnyCash])),
            ReferenceTrack("Warszawa", artist: "David Bowie", release: "Low", year: 1977,
                           bars: "0:00–1:30",
                           listenFor: "a procedure audible as form: the piece is built from a card's instruction rather than a "
                               + "song's, and the parts arrive one at a time",
                           features: [.partsPerSong, .versionsPerPart], evidence: .cited([lowBowie, oblique])),
            ReferenceTrack("Heart-Shaped Box", artist: "Nirvana", release: "In Utero", year: 1993,
                           bars: "the verse, bars 1–8",
                           listenFor: "the band as a document: room, bleed, a take played rather than assembled, and the "
                               + "refusal to fix it audible as air around the drums",
                           features: [.versionsPerPart], evidence: .cited([nirvanaUtero, albiniLetter])),
            ReferenceTrack("Nude", artist: "Radiohead", release: "In Rainbows", year: 2007,
                           bars: "the whole track; the ten years of versions before it",
                           listenFor: "a song redone across a decade and finished by subtraction — the released version is "
                               + "sparser than every earlier one",
                           features: [.versionsPerPart, .partsPerSong], evidence: .cited([inRainbows])),
        ],

        goldens: [
            GoldenTest("producer.golden.too-many-parts",
                       premise: "A tenth part is proposed for a song with nine, three of them in no section.",
                       passes: "Refused by producer.fewer-parts, naming the count, with subtraction as the counter.",
                       exercises: ["producer.fewer-parts", "producer.no-orphans"],
                       proposal: .addPart(partsInSong: 9, orphaned: 3), expects: .refuse(rule: "producer.fewer-parts")),
            GoldenTest("producer.golden.orphan",
                       premise: "A fifth part is proposed for a song with four, one of them in no section.",
                       passes: "Refused by producer.no-orphans: stitch the orphan or cut it before adding.",
                       exercises: ["producer.no-orphans"],
                       proposal: .addPart(partsInSong: 4, orphaned: 1), expects: .refuse(rule: "producer.no-orphans")),
            GoldenTest("producer.golden.room-to-add",
                       premise: "A fourth part is proposed for a song with three, every one of them in a section.",
                       passes: "Agreed: the song has room and nothing is orphaned.",
                       exercises: ["producer.fewer-parts"],
                       proposal: .addPart(partsInSong: 3, orphaned: 0), expects: .agree),
            GoldenTest("producer.golden.pushes-back",
                       premise: "\"Make it sound like Voodoo\" — a reference with no bars.",
                       passes: "Refused by producer.reference-has-bars with the counter that names bars.",
                       exercises: ["producer.reference-has-bars"],
                       proposal: .setReference(bars: 0), expects: .refuse(rule: "producer.reference-has-bars")),
            GoldenTest("producer.golden.reference-with-bars",
                       premise: "\"Hold it to bars 1–8 of Playa Playa.\"",
                       passes: "Agreed: eight bars is a place two people can put the needle.",
                       exercises: ["producer.reference-has-bars"],
                       proposal: .setReference(bars: 8), expects: .agree),
            GoldenTest("producer.golden.defers",
                       premise: "\"Swing the hats to 62%.\"",
                       passes: "Deferred to the Beatmaker rather than answered.",
                       exercises: [],
                       proposal: .setSwing(percent: 62, idiom: "boom-bap", tempo: 90), expects: .defer_(to: .beatmaker)),
        ],

        openQuestions: [
            OpenQuestion("producer.oq.parts-ceiling",
                         question: "Is eight the right ceiling on parts, or is it idiom-dependent?",
                         encoded: "Eight, from the sparse end of the lineages: Cash at two, Bowie's Low at five to eight, "
                                + "In Utero at four to six.",
                         alternative: "A ceiling per idiom — a lo-fi beat at four, a produced pop record at twelve — with the "
                                    + "brief naming the idiom and the ceiling following it.",
                         affects: ["producer.fewer-parts"],
                         evidence: .inferred("three lineages' records counted by ear")),
            OpenQuestion("producer.oq.churn",
                         question: "Is four versions churn, or is it work?",
                         encoded: "Four: Eno's diary rarely records more than three passes at a thing before the question changes.",
                         alternative: "Churn is not a count but a shape — versions that move less each time — and the rule "
                                    + "should read the size of the change, not the number of them.",
                         affects: ["producer.churn"],
                         evidence: .cited([swollen])),
            OpenQuestion("producer.oq.rubin-reduction",
                         question: "Does Rubin's reduction apply to sample-based music, where the parts are already few?",
                         encoded: "Yes: a chop, a groove and a bass line is three parts, and a fourth is the question.",
                         alternative: "In a sample idiom the parts are inside the chop, and reduction applies to slices and "
                                    + "layers rather than to parts — the Sampler's density is the Producer's count.",
                         affects: ["producer.fewer-parts", "producer.subtract-to-test"],
                         evidence: .cited([creativeAct])),
            OpenQuestion("producer.oq.albini-no-decisions",
                         question: "If the engineer makes no artistic decisions, is the Producer's call an artistic decision?",
                         encoded: "The Producer holds the brief and says no; the artist decides. The call is a reading of the "
                                + "brief, not a preference.",
                         alternative: "Every no is a decision, and the honest position is that the Producer is the only "
                                    + "persona allowed one — which is why it must write the brief down first.",
                         affects: ["producer.no-is-an-answer"],
                         evidence: .cited([albiniLetter])),
        ]
    )

    // MARK: - Considering a proposal

    /// The bible, run: every rule here is arithmetic over the song, and the engine says it.
    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(Producer.bible, proposal)
    }

    // MARK: - Reading a song

    /// The song, as the Producer counts it: parts, orphans, churn, the brief, the reference.
    public func read(_ observation: SongObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        let parts = Double(observation.partCount)
        notes.append(PersonaReading(
            rule: "producer.fewer-parts", feature: .partsPerSong, value: parts,
            holds: parts <= Producer.partsCeiling,
            says: parts <= Producer.partsCeiling
                ? "\(observation.partCount) part\(observation.partCount == 1 ? "" : "s"). Room to add, if the brief calls for it."
                : "\(observation.partCount) parts. That is a song that has not been subtracted from yet."))
        if observation.hasSections {
            let orphans = observation.orphanedParts
            notes.append(PersonaReading(
                rule: "producer.no-orphans", feature: .orphanedParts, value: Double(orphans.count),
                holds: orphans.isEmpty,
                says: orphans.isEmpty
                    ? "Every part is in a section."
                    : "\(orphans.count) part\(orphans.count == 1 ? " is" : "s are") in no section: \(orphans.joined(separator: ", ")). Stitch or cut."))
        }
        let churn = Double(observation.maximumVersions)
        notes.append(PersonaReading(
            rule: "producer.churn", feature: .versionsPerPart, value: churn,
            holds: churn <= Producer.churnCeiling,
            says: churn <= Producer.churnCeiling
                ? "Nothing has been redone more than \(observation.maximumVersions) time\(observation.maximumVersions == 1 ? "" : "s")."
                : "\(observation.mostRevised ?? "One part") is on version \(observation.maximumVersions). The next one is not the answer the last was not — change the question."))
        let words = Double(observation.briefWords)
        notes.append(PersonaReading(
            rule: "producer.brief-first", feature: .briefWords, value: words,
            holds: words >= 3,
            says: words >= 3 ? "The brief: \"\(observation.brief ?? "")\"." : "No brief. One sentence about what the song is about, before another part."))
        return notes
    }
}

// MARK: - What the Producer reads

/// The song, counted: what the Producer's rules are arithmetic over.
public struct SongObservation: Hashable, Sendable {
    public var label: String
    public var partCount: Int
    /// Titles of parts stitched into no section, when the song has sections.
    public var orphanedParts: [String]
    public var hasSections: Bool
    public var maximumVersions: Int
    public var mostRevised: String?
    public var brief: String?

    public var briefWords: Int { brief?.split(separator: " ").count ?? 0 }

    public init(label: String, partCount: Int, orphanedParts: [String], hasSections: Bool,
                maximumVersions: Int, mostRevised: String?, brief: String?) {
        self.label = label
        self.partCount = partCount
        self.orphanedParts = orphanedParts
        self.hasSections = hasSections
        self.maximumVersions = maximumVersions
        self.mostRevised = mostRevised
        self.brief = brief
    }

    /// Read off a song. Analyses and audio are not parts a Producer counts: they are the record,
    /// not decisions about it.
    public static func of(_ song: Song) -> SongObservation {
        let counted = song.partIDs.filter { id in
            song.latestVersion(of: id).map { ![PartType.analysis, .audio].contains($0.type) } ?? false
        }
        let stitched = Set(song.sections.flatMap(\.stitch).compactMap { song.version($0)?.partID })
        let orphans = song.sections.isEmpty ? [] : counted.filter { !stitched.contains($0) }
            .compactMap { song.latestVersion(of: $0) }.map { PartLabel.title(of: $0) }
        var most: (String, Int)?
        for id in counted {
            let n = song.versions(of: id).count
            if n > (most?.1 ?? 0), let latest = song.latestVersion(of: id) { most = (PartLabel.title(of: latest), n) }
        }
        let brief = song.seeds.compactMap { seed -> String? in
            if case .brief(let text) = seed.kind { return text }
            return nil
        }.last
        return SongObservation(label: song.title, partCount: counted.count, orphanedParts: orphans,
                               hasSections: !song.sections.isEmpty, maximumVersions: most?.1 ?? 0,
                               mostRevised: most?.0, brief: brief)
    }
}
