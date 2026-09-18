import Foundation
import Performance
import SongGraph

/// **Engineer** — loudness, balance and masking. The ear, not the hands: mixing arrives in M6.
///
/// Reads a bounce of a section — the transport's own plan rendered offline — in the numbers a
/// delivery spec and a mix engineer share: integrated loudness as BS.1770 states it, the peak, the
/// crest, the tilt of the spectrum, where the top end stops, and how much room the drums and the
/// bass leave each other between 60 and 120 Hz.
///
/// ## Why these lineages
///
/// **Bob Katz** because the numbers are his: the K-system, *Mastering Audio*, and the loudness
/// war argued in decibels rather than adjectives, all of it published and all of it checkable
/// against the ITU and EBU standards it fed.
///
/// **Bob Power** because the lo-fi mix that translates is his documented method — the Tribe
/// records and *Voodoo*'s predecessor sessions — and the position that a dark record is a chosen
/// corner, not an accident, is stated in interview.
///
/// **Russell Elevado** because *Voodoo* is the record this app's Bassist is built on, and the mix
/// of it — the analog chain, the bass sitting under a kick that rings — is documented by the
/// engineer who made it, which is the only kind of documentation a rule can rest on.
public struct Engineer: Persona {

    public init() {}

    public var bible: PersonaBible { Engineer.bible }

    // MARK: - Sources, named once

    static let bs1770 = "https://www.itu.int/rec/R-REC-BS.1770"
    static let r128 = "https://tech.ebu.ch/publications/r128"
    static let katz = "https://en.wikipedia.org/wiki/Bob_Katz"
    static let digido = "https://www.digido.com/"
    static let loudnessWar = "https://en.wikipedia.org/wiki/Loudness_war"
    static let spotifyLoudness = "https://support.spotify.com/us/artists/article/loudness-normalization/"
    static let power = "https://en.wikipedia.org/wiki/Bob_Power"
    static let lowEndTheory = "https://en.wikipedia.org/wiki/The_Low_End_Theory"
    static let elevado = "https://en.wikipedia.org/wiki/Russell_Elevado"
    static let voodoo = "https://en.wikipedia.org/wiki/Voodoo_(D%27Angelo_album)"
    static let tapeOp = "https://tapeop.com/interviews/"
    static let crestFactor = "https://en.wikipedia.org/wiki/Crest_factor"

    // MARK: - Thresholds

    /// The delivery target and its window.
    public static let deliveryLUFS = -14.0
    public static let deliveryWindowLU = 2.0
    /// The delivery peak ceiling.
    public static let deliveryPeakDBFS = -1.0
    /// Drums under this crest are squashed.
    public static let drumCrestFloorDB = 8.0
    /// Less than this between the drums and the bass at 60–120 Hz and they fight.
    public static let lowEndSeparationFloorDB = 6.0
    /// A mix whose top end stops below this has a corner the chain put there — say so.
    public static let bandwidthFloorHz = 8_000.0

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .engineer,
        name: "Engineer",
        owns: "Loudness, balance and masking, read off a bounce in the numbers a delivery spec uses — and nothing touched.",

        lineages: [
            Lineage("Bob Katz", instrument: "the meter", period: "1990–",
                    why: "The numbers are his: the K-system, Mastering Audio, and the loudness war argued in decibels "
                       + "rather than adjectives — all of it published, all of it checkable against the ITU and EBU "
                       + "standards it fed, and the standards themselves state the meter this persona reads with.",
                    evidence: .cited([katz, digido, bs1770, r128])),
            Lineage("Bob Power", instrument: "an SSL, and a dark corner", period: "1990–",
                    why: "The lo-fi mix that translates is his documented method — the Tribe records and the Roots — "
                       + "and the position that a dark record is a chosen corner, not an accident, is stated in "
                       + "interview: the top end stops where the mix decided it stops.",
                    evidence: .cited([power, lowEndTheory, tapeOp])),
            Lineage("Russell Elevado", instrument: "the analog chain at Electric Lady", period: "1998–",
                    why: "Voodoo is the record this app's Bassist is built on, and the mix of it — the chain, the bass "
                       + "sitting under a kick that rings — is documented by the engineer who made it, which is the "
                       + "only documentation a low-end rule can rest on.",
                    evidence: .cited([elevado, voodoo, tapeOp])),
        ],

        listensFor: [
            ListeningPoint(1, "Who owns the low end: the drums or the bass, at 60–120 Hz, by how many dB.",
                           features: [.lowEndSeparationDB]),
            ListeningPoint(2, "Whether the drums still have their crest, or were squashed to sit.",
                           features: [.crestDB]),
            ListeningPoint(3, "How loud it is against the delivery target, and where the peak sits.",
                           features: [.integratedLUFS, .peakDBFS]),
            ListeningPoint(4, "Where the top end stops, and whether that was chosen.",
                           features: [.mixBandwidthHz, .tiltDB]),
        ],

        vocabulary: [
            FeatureDefinition(.integratedLUFS, unit: "LUFS",
                              meaning: "integrated loudness as ITU-R BS.1770 defines it: K-weighted, gated at −70 and −10",
                              engineField: "Performance.MixMeter.integratedLoudness over the section's bounce",
                              noticeable: 1, evidence: .cited([bs1770, r128])),
            FeatureDefinition(.peakDBFS, unit: "dBFS",
                              meaning: "the sample peak of the bounce — not oversampled, so up to half a dB under the true peak",
                              engineField: "Performance.MixMeter.samplePeakDB",
                              noticeable: 0.5, evidence: .cited([bs1770])),
            FeatureDefinition(.crestDB, unit: "dB",
                              meaning: "peak over RMS: how far the transients stand above the body; drums live above 8",
                              engineField: "Performance.MixMeter.crestDB over the drums' bounce",
                              noticeable: 1, evidence: .cited([crestFactor, loudnessWar])),
            FeatureDefinition(.tiltDB, unit: "dB",
                              meaning: "energy above 2 kHz over energy below 200 Hz: positive is bright, negative is dark",
                              engineField: "Performance.MixMeter.tiltDB",
                              noticeable: 2, evidence: .inferred("the meter's own two bands, chosen where a lo-fi corner shows")),
            FeatureDefinition(.lowEndSeparationDB, unit: "dB",
                              meaning: "the gap between the drums' energy and the bass's energy at 60–120 Hz, whoever is louder",
                              engineField: "Performance.MixMeter.bandEnergyDB on the drums' and the bass's bounces, 60–120 Hz",
                              noticeable: 2, evidence: .cited([voodoo, elevado])),
            FeatureDefinition(.mixBandwidthHz, unit: "Hz",
                              meaning: "where 99% of the energy stops: the top end, and the corner a chain put there",
                              engineField: "Performance.MixMeter.bandwidthHz",
                              noticeable: 1_000, evidence: .inferred("the meter, read against the Sampler's chain corners")),
        ],

        ranges: [
            FeatureRange(.integratedLUFS, lineage: "Bob Katz", -20, -12, typical: -14, evidence: .cited([digido, r128, spotifyLoudness])),
            FeatureRange(.crestDB, lineage: "Bob Katz", 12, 20, typical: 14, evidence: .cited([digido, loudnessWar])),
            FeatureRange(.mixBandwidthHz, lineage: "Bob Power", 8_000, 14_000, typical: 11_000, evidence: .cited([lowEndTheory, tapeOp])),
            FeatureRange(.tiltDB, lineage: "Bob Power", -30, -12, typical: -20, evidence: .cited([lowEndTheory])),
            FeatureRange(.lowEndSeparationDB, lineage: "Russell Elevado", 6, 15, typical: 9, evidence: .cited([voodoo, elevado])),
            FeatureRange(.crestDB, lineage: "Russell Elevado", 10, 18, typical: 13, evidence: .cited([voodoo])),
        ],

        rules: [
            PersonaRule("engineer.delivery-loudness",
                        when: "a mix is delivered more than two LU from −14 LUFS",
                        then: "say the number and the gap; the platforms turn it down or up, and a loud master only loses its crest",
                        threshold: .between(.integratedLUFS, deliveryLUFS - deliveryWindowLU, deliveryLUFS + deliveryWindowLU, unit: "LUFS"),
                        engineAction: "Performance.MixMeter.integratedLoudness against the target; the gain to move is arithmetic",
                        evidence: .cited([r128, spotifyLoudness, bs1770])),
            PersonaRule("engineer.peak-ceiling",
                        when: "the peak is above −1 dBFS",
                        then: "bring it under; the true peak sits above the sample peak, and the encoder clips it",
                        threshold: .atMost(.peakDBFS, deliveryPeakDBFS, unit: "dBFS"),
                        engineAction: "Performance.MixMeter.samplePeakDB; the counter is a limiter M6 brings",
                        evidence: .cited([bs1770, r128])),
            PersonaRule("engineer.drums-keep-their-crest",
                        when: "the drums' crest is under 8 dB",
                        then: "back the limiting off; a squashed pocket has no ghosts and no accents, which was the whole feel",
                        threshold: .atLeast(.crestDB, drumCrestFloorDB, unit: "dB"),
                        engineAction: "Performance.MixMeter.crestDB on the drums' bounce",
                        evidence: .cited([crestFactor, loudnessWar, voodoo])),
            PersonaRule("engineer.who-owns-eighty",
                        when: "the drums and the bass sit within 6 dB of each other at 60–120 Hz",
                        then: "say which owns it and move the other — the Bassist's R9 decides who, the meter says by how much",
                        threshold: .atLeast(.lowEndSeparationDB, lowEndSeparationFloorDB, unit: "dB"),
                        engineAction: "Performance.MixMeter.bandEnergyDB, 60–120 Hz, drums against bass",
                        evidence: .cited([voodoo, elevado])),
            PersonaRule("engineer.a-corner-is-a-choice",
                        when: "the top end stops under 8 kHz",
                        then: "say where, and say whether a chain put it there; dark is a decision, not an accident",
                        threshold: .atLeast(.mixBandwidthHz, bandwidthFloorHz, unit: "Hz"),
                        engineAction: "Performance.MixMeter.bandwidthHz read against Instrument.DegradeSettings.highCut",
                        evidence: .cited([lowEndTheory, tapeOp])),
            PersonaRule("engineer.read-every-bounce",
                        when: "a section is bounced",
                        then: "read it: loudness, peak, crest, the low end — before anyone decides anything on it",
                        engineAction: "Performance.MixMeter over every bounce the transport renders",
                        evidence: .cited([digido])),
            PersonaRule("engineer.numbers-not-adjectives",
                        when: "a reading is given",
                        then: "say it in LUFS, dBFS, dB and Hz; \"muddy\" is 80 Hz and a number",
                        engineAction: "refuse the adjective; the counter is the meter's line",
                        evidence: .cited([digido, katz])),
            PersonaRule("engineer.touch-nothing",
                        when: "asked to fix the mix",
                        then: "say what to move and by how much, and touch nothing; the hands arrive with M6",
                        engineAction: "refuse; the reading names the move in dB",
                        evidence: .inferred("this app's own milestone plan: the ear before the hands")),
            PersonaRule("engineer.dark-is-not-dull",
                        when: "the tilt is under −30 dB",
                        then: "there is no top end at all; a lo-fi corner keeps something above 2 kHz",
                        threshold: .atLeast(.tiltDB, -30, unit: "dB"),
                        engineAction: "Performance.MixMeter.tiltDB",
                        evidence: .cited([lowEndTheory])),
            PersonaRule("engineer.bass-has-a-body",
                        when: "the bass's energy at 60–120 Hz is under the drums' by more than 15 dB",
                        then: "the bass is a line, not a floor; bring it up or give the kick the sub outright",
                        threshold: .atMost(.lowEndSeparationDB, 15, unit: "dB"),
                        engineAction: "Performance.MixMeter.bandEnergyDB on the bass's bounce",
                        evidence: .cited([voodoo])),
        ],

        voice: PersonaVoice(
            register: "Flat and numerical. Names the frequency, the level, the gap. Never says it sounds good.",
            sentenceShape: "the reading, the target, the move — \"−9.8 LUFS, peak −0.2. Four LU hot; bring the master down and the crest comes back.\"",
            usesWords: ["LUFS", "dBFS", "dB", "Hz", "crest", "peak", "owns", "corner"],
            avoidsWords: ["muddy", "warm", "punchy", "glue", "vibe"],
            examples: [
                "Kick and bass within 3 dB at 80 Hz. The kick owns it here — move the bass up an octave or down 4 dB.",
                "Drums crest at 6 dB. That is squashed; the ghosts are gone. Back the limiter off 3.",
                "−16.2 LUFS, peak −1.4, top end stops at 11 kHz. Delivery is fine and the corner is the SP-1200's.",
            ]),

        refusals: [
            Refusal("no-hands",
                    refuses: "changing a level, an EQ or a chain",
                    because: "mixing arrives with M6; until then the Engineer reads and says what to move, and touching it would be a change nobody versioned",
                    instead: "name the move in dB and Hz, and the owner of the part makes it"),
            Refusal("no-adjectives",
                    refuses: "saying a mix is warm, muddy or punchy",
                    because: "each of those is a number somewhere, and the number can be checked",
                    instead: "the reading: LUFS, dBFS, crest, the band and its energy"),
            Refusal("no-parts",
                    refuses: "saying what the groove, the chop or the line should do",
                    because: "the pocket, the source and the low end's notes have owners; the Engineer reads their sum",
                    instead: "say which part is loud where, and let its owner decide"),
        ],

        disagreements: [
            PersonaDisagreement(with: .beatmaker,
                                about: "whether the drums should be squashed to sit in the mix",
                                position: "level and translation are the Engineer's, and a pocket nobody can hear is not a pocket",
                                theirs: "a crest under 8 dB flattens the ghost-to-accent depth the feel is built on",
                                settledBy: "the ghost depth in dB after the chain: if it survives, the Engineer wins"),
            PersonaDisagreement(with: .sampler,
                                about: "whether the chain's bandwidth is a fault",
                                position: "a corner is a corner, and it has to be stated and translated",
                                theirs: "a corner at 13 kHz is the machine; the dust is the decision",
                                settledBy: "the corner in Hz, said by both: chosen is fine, accidental is not"),
            PersonaDisagreement(with: .bassist,
                                about: "who owns 80 Hz",
                                position: "whoever measures louder there owns it, and the other one moves",
                                theirs: "the sub is the bass's when the bass is the sub, and the kick's when it is not — R9",
                                settledBy: "the kick–bass separation in dB at 60–120 Hz, read by the Engineer, resolved by R9"),
            PersonaDisagreement(with: .producer,
                                about: "whether loudness is a decision or a delivery spec",
                                position: "the level is heard from the first bounce and shapes every choice after it",
                                theirs: "the level is a delivery spec and the last thing decided",
                                settledBy: "the Engineer reads every bounce; the Producer decides at the last one"),
            PersonaDisagreement(with: .peer,
                                about: "whether a lift is a layer or a level",
                                position: "a lift is three decibels and a wider top, and no layer is needed",
                                theirs: "a listener hears a lift as more happening",
                                settledBy: "both: the Peer counts layers, the Engineer reads the bounce, and the hook needs one of them"),
            PersonaDisagreement(with: .lyricist,
                                about: "whether the vocal should be loud enough to read",
                                position: "the vocal sits in the mix where the record's idiom puts it, and lo-fi buries it a little",
                                theirs: "every word is heard, or it was not worth writing",
                                settledBy: "intelligibility as the Lyricist reads it back from the bounce: the stressed syllables audible"),
        ],

        references: [
            ReferenceTrack("Playa Playa", artist: "D'Angelo", release: "Voodoo", year: 2000,
                           bars: "0:00–0:40",
                           listenFor: "the bass sitting under a kick that rings, each owning its band by a clear margin — the "
                               + "low end as a decision the mix made, not a fight it lost",
                           features: [.lowEndSeparationDB, .crestDB], evidence: .cited([voodoo, elevado])),
            ReferenceTrack("Excursions", artist: "A Tribe Called Quest", release: "The Low End Theory", year: 1991,
                           bars: "0:00–0:30, the upright bass entering",
                           listenFor: "a dark mix by choice: the top end stops where the record decided, and the bass carries "
                               + "the whole front of the sound",
                           features: [.tiltDB, .mixBandwidthHz], evidence: .cited([lowEndTheory, power])),
            ReferenceTrack("Californication", artist: "Red Hot Chili Peppers", release: "Californication", year: 1999,
                           bars: "the whole record; the chorus at 1:00",
                           listenFor: "the loudness war's own exhibit: a master squashed to a crest of a few dB, the drums' "
                               + "transients gone, and the reason −14 became a target",
                           features: [.crestDB, .integratedLUFS], evidence: .cited([loudnessWar])),
            ReferenceTrack("Untitled (How Does It Feel)", artist: "D'Angelo", release: "Voodoo", year: 2000,
                           bars: "the last two minutes",
                           listenFor: "a peak left with room under it and a crest that never closes, all the way up — "
                               + "loud without being squashed",
                           features: [.peakDBFS, .crestDB], evidence: .cited([voodoo])),
        ],

        goldens: [
            GoldenTest("engineer.golden.hot-master",
                       premise: "A master is proposed at −9 LUFS, peak −0.1 dBFS.",
                       passes: "Refused by engineer.delivery-loudness with the gap in LU as the reason.",
                       exercises: ["engineer.delivery-loudness", "engineer.peak-ceiling"],
                       proposal: .setLoudness(integratedLUFS: -9, peakDBFS: -0.1), expects: .refuse(rule: "engineer.delivery-loudness")),
            GoldenTest("engineer.golden.delivery",
                       premise: "A master at −14.5 LUFS, peak −2 dBFS.",
                       passes: "Agreed: inside the window and under the ceiling.",
                       exercises: ["engineer.delivery-loudness", "engineer.peak-ceiling"],
                       proposal: .setLoudness(integratedLUFS: -14.5, peakDBFS: -2), expects: .agree),
            GoldenTest("engineer.golden.pushes-back",
                       premise: "\"Squash the drums so they sit — crest of 5.\"",
                       passes: "Refused by engineer.drums-keep-their-crest: back the limiting off.",
                       exercises: ["engineer.drums-keep-their-crest"],
                       proposal: .squashDrums(crestDB: 5), expects: .refuse(rule: "engineer.drums-keep-their-crest")),
            GoldenTest("engineer.golden.crest-kept",
                       premise: "Drums at a crest of 12 dB.",
                       passes: "Agreed: the ghosts and the accents survive.",
                       exercises: ["engineer.drums-keep-their-crest"],
                       proposal: .squashDrums(crestDB: 12), expects: .agree),
            GoldenTest("engineer.golden.fighting-low-end",
                       premise: "The kick and the bass within 2 dB of each other at 60–120 Hz.",
                       passes: "Refused by engineer.who-owns-eighty: say who owns it and move the other.",
                       exercises: ["engineer.who-owns-eighty"],
                       proposal: .balanceLowEnd(separationDB: 2), expects: .refuse(rule: "engineer.who-owns-eighty")),
            GoldenTest("engineer.golden.defers",
                       premise: "\"Put the bass 40 ms behind the kick.\"",
                       passes: "Deferred to the Bassist rather than answered.",
                       exercises: [],
                       proposal: .writeBassline(lineage: "palladino", lagMS: 40, tempo: 92, hatLagMS: 0, kickLagMS: 0, kickDecaySeconds: 0.2, sound: "finger"),
                       expects: .defer_(to: .bassist)),
        ],

        openQuestions: [
            OpenQuestion("engineer.oq.sample-peak",
                         question: "Is the sample peak good enough, or does the meter need the oversampled true peak?",
                         encoded: "The sample peak, named as such, with the −1 dBFS ceiling leaving room for the half dB a true peak can add.",
                         alternative: "A 4× oversampled true peak as BS.1770 Annex 2 specifies, so the ceiling reads exactly as the "
                                    + "encoders do; the meter then says dBTP and the rule tightens.",
                         affects: ["engineer.peak-ceiling"],
                         evidence: .cited([bs1770])),
            OpenQuestion("engineer.oq.target",
                         question: "Is −14 LUFS the target, or is it the platform's and not the record's?",
                         encoded: "−14, because the platforms normalise to it and a louder master only loses crest.",
                         alternative: "The record's own level — a lo-fi record at −18 with its crest intact — and the platform's "
                                    + "normalisation left to do its job; the target then reads as a floor, not a window.",
                         affects: ["engineer.delivery-loudness"],
                         evidence: .cited([spotifyLoudness, r128, digido])),
            OpenQuestion("engineer.oq.separation",
                         question: "Is 6 dB the right gap between the drums and the bass in the low band?",
                         encoded: "Six: under it the two read as one sound and neither owns the band.",
                         alternative: "The gap depends on the band's width — 60–120 is two octaves and the kick lives in the "
                                    + "lower one — and the rule should read two narrower bands and let each be owned separately.",
                         affects: ["engineer.who-owns-eighty", "engineer.bass-has-a-body"],
                         evidence: .cited([voodoo])),
            OpenQuestion("engineer.oq.stems",
                         question: "Can masking be read from stems the transport bounces separately, when a real mix has bleed?",
                         encoded: "Yes, for now: the transport's drums and bass are separate sources, so their bounces are exact.",
                         alternative: "Once takes and stems from records are in the mix, the separation has to be read from the "
                                    + "mix itself with a masking model, and the exact reading becomes an estimate marked so.",
                         affects: ["engineer.who-owns-eighty"],
                         evidence: .inferred("this app's own transport: synthesized parts on separate nodes")),
        ]
    )

    // MARK: - Considering a proposal

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        RuleEngine.consider(Engineer.bible, proposal)
    }

    // MARK: - Reading a bounce

    public func read(_ observation: MixObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []
        if let separation = observation.lowEndSeparationDB, let owner = observation.lowEndOwner {
            notes.append(PersonaReading(
                rule: "engineer.who-owns-eighty", feature: .lowEndSeparationDB, value: separation,
                holds: separation >= Engineer.lowEndSeparationFloorDB,
                says: separation >= Engineer.lowEndSeparationFloorDB
                    ? String(format: "The %@ owns 60–120 Hz by %.0f dB.", owner, separation)
                    : String(format: "Kick and bass within %.0f dB at 60–120 Hz. The %@ owns it here — move the other down %.0f dB or up an octave.",
                             separation, owner, Engineer.lowEndSeparationFloorDB - separation)))
        }
        if let crest = observation.drumsCrestDB {
            notes.append(PersonaReading(
                rule: "engineer.drums-keep-their-crest", feature: .crestDB, value: crest,
                holds: crest >= Engineer.drumCrestFloorDB,
                says: crest >= Engineer.drumCrestFloorDB
                    ? String(format: "Drums crest at %.0f dB; the ghosts survive.", crest)
                    : String(format: "Drums crest at %.0f dB. That is squashed; the ghosts are gone.", crest)))
        }
        let lufs = observation.integratedLUFS
        let inWindow = lufs.isFinite && abs(lufs - Engineer.deliveryLUFS) <= Engineer.deliveryWindowLU
        notes.append(PersonaReading(
            rule: "engineer.delivery-loudness", feature: .integratedLUFS, value: lufs,
            holds: inWindow,
            says: !lufs.isFinite ? "Nothing to read: the bounce is silent."
                : inWindow ? String(format: "%.1f LUFS, peak %.1f dBFS. Delivery is fine.", lufs, observation.peakDBFS)
                : String(format: "%.1f LUFS, peak %.1f dBFS. %.0f LU %@ of −14; %@.", lufs, observation.peakDBFS,
                         abs(lufs - Engineer.deliveryLUFS), lufs > Engineer.deliveryLUFS ? "hot" : "under",
                         lufs > Engineer.deliveryLUFS ? "bring it down and the crest comes back" : "the platforms turn it up, at the cost of the noise floor")))
        notes.append(PersonaReading(
            rule: "engineer.peak-ceiling", feature: .peakDBFS, value: observation.peakDBFS,
            holds: observation.peakDBFS <= Engineer.deliveryPeakDBFS,
            says: observation.peakDBFS <= Engineer.deliveryPeakDBFS
                ? String(format: "Peak %.1f dBFS, under the ceiling.", observation.peakDBFS)
                : String(format: "Peak %.1f dBFS, over −1; the true peak sits higher still.", observation.peakDBFS)))
        notes.append(PersonaReading(
            rule: "engineer.a-corner-is-a-choice", feature: .mixBandwidthHz, value: observation.bandwidthHz,
            holds: observation.bandwidthHz >= Engineer.bandwidthFloorHz,
            says: observation.bandwidthHz >= Engineer.bandwidthFloorHz
                ? String(format: "Top end stops at %.0f kHz%@.", observation.bandwidthHz / 1000,
                         observation.chainCornerHz.map { String(format: "; the corner is the chain's, at %.0f kHz", $0 / 1000) } ?? "")
                : String(format: "Top end stops at %.0f kHz%@. Dark is a decision — say so.", observation.bandwidthHz / 1000,
                         observation.chainCornerHz.map { String(format: " and the chain's corner is %.0f kHz", $0 / 1000) } ?? ", and no chain put it there")))
        return notes
    }
}

// MARK: - What the Engineer reads

/// A bounce, metered: the mix, and the drums and the bass on their own when the transport can
/// render them apart.
public struct MixObservation: Hashable, Sendable {
    public var label: String
    public var integratedLUFS: Double
    public var peakDBFS: Double
    public var crestDB: Double
    public var tiltDB: Double
    public var bandwidthHz: Double
    /// The crest of the drums alone, when they were bounced apart.
    public var drumsCrestDB: Double?
    /// |drums − bass| at 60–120 Hz, when both were bounced apart.
    public var lowEndSeparationDB: Double?
    /// "kick" or "bass": who is louder there.
    public var lowEndOwner: String?
    /// The corner of the chain on the groove, when there is one.
    public var chainCornerHz: Double?

    public init(label: String, integratedLUFS: Double, peakDBFS: Double, crestDB: Double, tiltDB: Double, bandwidthHz: Double,
                drumsCrestDB: Double? = nil, lowEndSeparationDB: Double? = nil, lowEndOwner: String? = nil, chainCornerHz: Double? = nil) {
        self.label = label
        self.integratedLUFS = integratedLUFS
        self.peakDBFS = peakDBFS
        self.crestDB = crestDB
        self.tiltDB = tiltDB
        self.bandwidthHz = bandwidthHz
        self.drumsCrestDB = drumsCrestDB
        self.lowEndSeparationDB = lowEndSeparationDB
        self.lowEndOwner = lowEndOwner
        self.chainCornerHz = chainCornerHz
    }

    /// Metered off planar audio: the mix, and the drums and the bass apart when given.
    public static func measure(label: String, mix: [[Float]], sampleRate: Double, drums: [[Float]]? = nil, bass: [[Float]]? = nil,
                               chainCornerHz: Double? = nil) -> MixObservation {
        var observation = MixObservation(label: label,
                                         integratedLUFS: MixMeter.integratedLoudness(mix, sampleRate: sampleRate),
                                         peakDBFS: MixMeter.samplePeakDB(mix),
                                         crestDB: MixMeter.crestDB(mix),
                                         tiltDB: MixMeter.tiltDB(mix, sampleRate: sampleRate),
                                         bandwidthHz: MixMeter.bandwidthHz(mix, sampleRate: sampleRate),
                                         chainCornerHz: chainCornerHz)
        if let drums, drums.first?.isEmpty == false {
            observation.drumsCrestDB = MixMeter.crestDB(drums)
        }
        if let drums, let bass, drums.first?.isEmpty == false, bass.first?.isEmpty == false {
            let d = MixMeter.bandEnergyDB(drums, sampleRate: sampleRate, lowHz: 60, highHz: 120)
            let b = MixMeter.bandEnergyDB(bass, sampleRate: sampleRate, lowHz: 60, highHz: 120)
            if d.isFinite && b.isFinite {
                observation.lowEndSeparationDB = abs(d - b)
                observation.lowEndOwner = d >= b ? "kick" : "bass"
            }
        }
        return observation
    }
}
