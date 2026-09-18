import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// **Sampler** — chop choice, source character and degradation.
///
/// Which slice earns a pad, where a cut belongs relative to the transient it was taken from, when a
/// source wants bit reduction or tape or vinyl, and — the part that is actually hard — when to leave
/// it alone. It does not set swing and it does not move a voice; that is the Beatmaker's.
///
/// ## Why these lineages
///
/// **The E-mu SP-1200** because it is the only lineage in this field whose constraints are published
/// to the digit, and because one of those digits is a *compositional* fact rather than a spec.
/// Twelve bits, 26.04 kHz, ten seconds of memory — and **two and a half seconds per sample**. One
/// bar of 4/4 at 90 BPM is 2.67 seconds. The machine physically could not hold a bar at hip-hop
/// tempo, so chopping below the bar was forced rather than chosen, and the whole aesthetic of
/// rearranging a break rather than looping it starts as a memory limit. That is the kind of fact a
/// rule can be built on.
///
/// **Madlib** because the SP-303 method is documented end to end and is structurally different from
/// everything that came after: eight pads to a bank, **one effect at a time**, and the effect printed
/// at the moment of capture rather than applied afterwards. Most of *Madvillainy* was made in a São
/// Paulo hotel room with a portable turntable, a battery-powered SP-303 and the hotel's own cassette
/// deck, with the 303's output recorded straight to tape. A persona that stacks three chains has
/// misunderstood the whole lineage.
///
/// **DJ Shadow** because he is the best-documented set of *rules* in the search, even where the
/// gear detail is thin. An MPC60 MkII with 12.5 seconds of stereo memory, and his stated workaround
/// — resample anything not genuinely stereo to mono purely to reclaim length. And the rule worth
/// more than any spec: vary the drum elements continuously across roughly twenty sequences rather
/// than looping a bar, which he credits to Pete Rock almost never repeating a drum pattern.
///
/// ## What was dropped, and why
///
/// **RZA and *Enter the Wu-Tang (36 Chambers)* were the obvious third lineage and the premise is
/// wrong.** That album is not an SP-1200 record. The engineer's own account has RZA's Ensoniq
/// machines doing the sampling and sequencing — which means 16-bit at 29.76 kHz on an ASR-10 or
/// 16-bit at a variable rate on an EPS-16 Plus, not 12-bit at 26.04 kHz. RZA did own an SP-1200 (his
/// first sold at auction for nearly $70,000) but no source establishes its role on that record. The
/// grit came from the signal chain — six API preamps, 1176s, a Pultec, two-inch tape — and from
/// engineers who deliberately preserved rather than polished. A "36 Chambers" preset built on the
/// SP-1200's numbers would model the wrong machine, so this bible does not ship one. See
/// `sampler.oq.rza`.
public struct Sampler: Persona {

    public init() {}

    public var bible: PersonaBible { Sampler.bible }

    // MARK: - Sources, named once

    static let sp1200 = "https://en.wikipedia.org/wiki/E-mu_SP-1200"
    static let mpc60Spec = "https://www.vintagesynth.com/akai/mpc60"
    static let s950 = "https://www.vintagedigital.com.au/akai-s950/"
    static let sp303 = "https://en.wikipedia.org/wiki/Boss_SP-303"
    static let sp303MusicTech = "https://musictech.com/features/boss-sp-303-hip-hop-connection-j-dilla-madlib-mf-doom/"
    static let madvillainy = "https://en.wikipedia.org/wiki/Madvillainy"
    static let madlibRemix = "https://www.stonesthrow.com/news/phantom-menace-remix-mag-interview-with-madlib-and-engineer-dave-cooley/"
    static let shadowSOS = "https://www.soundonsound.com/techniques/classic-tracks-dj-shadow-midnight-perfect-world"
    static let endtroducing = "https://en.wikipedia.org/wiki/Endtroducing....."
    static let lostArt = "https://www.soundonsound.com/techniques/lost-art-sampling-part-4"
    static let dynamicRange = "https://en.wikipedia.org/wiki/Dynamic_range"
    static let tascam424 = "https://homerecording.com/tas424specs.html"
    static let attackSlices = "https://www.attackmagazine.com/technique/tutorials/programming-and-layering-sliced-drum-breaks-for-use-in-techno/"
    static let sliceLate = "https://sampleroll.com/blog/chopping-by-transients-how-to"
    static let wuTangRBMA = "https://daily.redbullmusicacademy.com/2018/06/engineering-wu-tang-clan/"
    static let sp404Manual = "https://static.roland.com/manuals/sp-404mk2_reference/eng/17805541.html"
    static let heinGetDisMoney = "https://www.ethanhein.com/wp/2022/get-dis-money/"

    // MARK: - Lineage names

    public static let sp1200School = "The E-mu SP-1200"
    public static let madlib = "Madlib"
    public static let shadow = "DJ Shadow"

    // MARK: - Thresholds, as constants the rules and the tests share

    /// The longest single sample an SP-1200 could hold, in seconds.
    public static let sp1200SampleSeconds: Double = 2.5
    /// The tempo at which one bar of 4/4 stops fitting in that: 4 × 60/96 = 2.5 s exactly. Below
    /// this the bar does not fit and the lineage had to chop inside it.
    public static let barFitsAboveBPM: Double = 96
    /// Pads in one SP-303 bank. The ceiling on a chop in that lineage.
    public static let sp303Pads = 8
    /// Attack Magazine's published figure: at full sensitivity a break slices at every transient,
    /// which is too many; at 22% it yields fourteen slices and keeps the live feel. Sixteen is that
    /// figure rounded up to the nearest musical number.
    public static let workableSlices = 16
    /// Where a cut becomes a mistake: this many milliseconds after its transient.
    public static let shaveLimitMS: Double = 2
    /// A microgroove LP's dynamic range, in dB — the floor a vinyl-sourced sample already carries.
    public static let vinylDynamicRange: ClosedRange<Double> = 55...65
    /// A compact cassette's.
    public static let cassetteDynamicRange: ClosedRange<Double> = 50...56
    /// Wow and flutter on a real Tascam Portastudio 424, as a percentage: 0.06% WRMS at 1-7/8 ips,
    /// 0.05% at 3-3/4. This app's own cassette preset runs 0.12% wow plus 0.06% flutter — about
    /// three times the deck — which is a deliberate exaggeration and is written down as one.
    public static let portastudioWowFlutter: ClosedRange<Double> = 0.05...0.06

    // MARK: - The bible

    public static let bible = PersonaBible(
        id: .sampler,
        name: "Sampler",
        owns: "Chop choice, source character and degradation: which slice earns a pad, where the cut "
            + "belongs, and when to leave a source alone.",

        lineages: [
            Lineage(sp1200School, instrument: "E-mu SP-1200", period: "1987–1995",
                    why: "The only lineage whose constraints are published to the digit — 12 bits linear, "
                       + "26.04 kHz, ten seconds of memory, two and a half seconds per sample — and the "
                       + "only one where a spec is also a compositional rule. A bar of 4/4 at 90 BPM is "
                       + "2.67 seconds, so the machine could not hold one, and chopping inside the bar "
                       + "started as a memory limit rather than as an aesthetic. Its unfiltered "
                       + "drop-sample path is also exactly what this app's `sp1200` preset models.",
                    evidence: .cited([sp1200])),

            Lineage(madlib, instrument: "Boss SP-303 into a cassette deck", period: "2000–2005",
                    why: "The method is documented end to end and is structurally unlike anything after "
                       + "it: eight pads to a bank, one effect at a time, and the effect printed at "
                       + "capture rather than applied later. Most of Madvillainy was made in a São Paulo "
                       + "hotel room with a portable turntable, a battery-powered 303 and the hotel's own "
                       + "cassette deck, recorded straight to tape. He also samples from cassette, VCR "
                       + "and whatever else — source fidelity is explicitly not a gate.",
                    evidence: .cited([madlibRemix, madvillainy, sp303MusicTech])),

            Lineage(shadow, instrument: "Akai MPC60 MkII, Technics SL-1200, Alesis ADAT", period: "1992–1996",
                    why: "The best-documented set of *rules* in the field even where the gear detail is "
                       + "thin. Twelve and a half seconds of stereo memory, and the stated workaround of "
                       + "resampling anything not genuinely stereo to mono to reclaim it. And the rule "
                       + "worth more than any spec: vary the drum elements across the whole arrangement "
                       + "rather than looping a bar — roughly twenty sequences without repeating — which "
                       + "he credits to Pete Rock almost never repeating a drum pattern.",
                    evidence: .cited([shadowSOS, endtroducing])),
        ],

        // MARK: Listening order

        listensFor: [
            ListeningPoint(1, "Whether any cut landed after its transient — the one unambiguous mistake.",
                           features: [.attackShaveMS]),
            ListeningPoint(2, "Whether the source has anything left for a chain to take.",
                           features: [.bandwidthHz, .holdRateHz, .bitDepth]),
            ListeningPoint(3, "Whether the slices can survive being played against each other.",
                           features: [.sliceSpreadDB, .sliceFloorDB]),
            ListeningPoint(4, "How many slices there are against how many the material actually has.",
                           features: [.sliceDensity]),
            ListeningPoint(5, "Whether the source is already noisy, and by how much.",
                           features: [.wowPercent, .crackleDensity, .drive]),
        ],

        // MARK: Feature vocabulary

        vocabulary: [
            FeatureDefinition(.attackShaveMS, unit: "ms, positive = the cut is late",
                              meaning: "how far a cut sits after the transient it was taken from, which is the "
                                     + "amount of attack left on the previous pad",
                              engineField: "Performance.Slice.snapOffset, positive; or the gap from the nearest "
                                         + "detected onset at or before Slice.startSeconds",
                              noticeable: shaveLimitMS,
                              evidence: .cited([s950, sliceLate])),
            FeatureDefinition(.sliceDensity, unit: "slices per bar",
                              meaning: "how finely the bar was cut",
                              engineField: "Performance.Chop.count against Chop.duration and detectedTempo",
                              noticeable: 2,
                              evidence: .cited([attackSlices, sp303])),
            FeatureDefinition(.gridDeviationMS, unit: "ms",
                              meaning: "how far the average cut had to move to reach a grid line — a measure of "
                                     + "how far off the grid the source was played",
                              engineField: "mean |Performance.Slice.snapOffset| over the snapped slices",
                              noticeable: 5,
                              evidence: .inferred("derived from Chopper.snapTolerance, which is 25 ms")),
            FeatureDefinition(.bitDepth, unit: "bits",
                              meaning: "the quantiser's width; 12 is both the SP-1200 and the MPC60, 24 and up "
                                     + "is the stage off",
                              engineField: "Instrument.DegradeSettings.bitDepth",
                              noticeable: 0.5,
                              evidence: .cited([sp1200, mpc60Spec])),
            FeatureDefinition(.holdRateHz, unit: "Hz",
                              meaning: "the rate the decimator holds to — 26.04 kHz is the SP-1200's, 40 kHz the "
                                     + "MPC60's, and the difference between them is a Nyquist at 13 kHz against "
                                     + "one at 20",
                              engineField: "Instrument.DegradeSettings.targetSampleRate",
                              noticeable: 500,
                              evidence: .cited([sp1200, mpc60Spec])),
            FeatureDefinition(.bandwidthHz, unit: "Hz",
                              meaning: "the frequency below which 95% of the source's energy already sits",
                              engineField: "SourceMeasurement.rolloff, against DegradeSettings.highCut",
                              noticeable: 500,
                              evidence: .inferred("measured with the same STFT the SliceClassifier uses, so a "
                                                + "rolloff and a centroid agree about the spectrum")),
            FeatureDefinition(.sliceFloorDB, unit: "dBFS",
                              meaning: "the peak of the quietest sounding slice",
                              engineField: "Performance.Slice.peakDB",
                              noticeable: 3,
                              evidence: .cited([dynamicRange])),
            FeatureDefinition(.sliceSpreadDB, unit: "dB",
                              meaning: "loudest minus quietest inside one class — what decides whether a "
                                     + "rotating policy produces a groove or a groove that ducks",
                              engineField: "Performance.Slice.peakDB grouped by SliceClassification.kind",
                              noticeable: 3,
                              evidence: .inferred("the threshold is the VelocityMap's own dynamic range; the "
                                                + "measurement is the engine's")),
            FeatureDefinition(.wowPercent, unit: "% peak pitch deviation",
                              meaning: "the transport's slow wobble; a real Portastudio is specified at "
                                     + "0.05–0.06% WRMS for wow and flutter together",
                              engineField: "Instrument.DegradeSettings.wowDepth × 100",
                              noticeable: 0.01,
                              evidence: .cited([tascam424])),
            FeatureDefinition(.crackleDensity, unit: "events per second",
                              meaning: "surface noise events; this app's vinyl preset runs twelve a second",
                              engineField: "Instrument.DegradeSettings.crackleDensity",
                              noticeable: 2,
                              evidence: .inferred("read off this app's own vinyl preset; no published figure "
                                                + "for crackle rate exists")),
            FeatureDefinition(.drive, unit: "linear gain",
                              meaning: "gain into the saturation curve; the SP-1200 preset uses 1.40 and the "
                                     + "MPC60 preset 1.20 as stand-ins for the machines' output stages",
                              engineField: "Instrument.DegradeSettings.drive",
                              noticeable: 0.1,
                              evidence: .inferred("this app's own presets; no engineering-grade figure for tape "
                                                + "or converter saturation onset was findable")),
            FeatureDefinition(.tempoBPM, unit: "BPM",
                              meaning: "the tempo the source was cut at, which decides whether a bar fits in a "
                                     + "sampler's memory",
                              engineField: "Performance.Chop.detectedTempo",
                              noticeable: 2,
                              evidence: .cited([sp1200])),
        ],

        // MARK: Ranges per lineage

        ranges: [
            FeatureRange(.bitDepth, lineage: sp1200School, 12, 12, typical: 12, evidence: .cited([sp1200])),
            FeatureRange(.holdRateHz, lineage: sp1200School, 26040, 26040, typical: 26040,
                         evidence: .cited([sp1200])),
            FeatureRange(.bandwidthHz, lineage: sp1200School, 0, 13020, typical: 12000,
                         evidence: .inferred("Nyquist of 26.04 kHz is 13.02 kHz; the 12 kHz figure is this "
                                           + "app's own sp1200 preset corner, set below it for the analog "
                                           + "output stage")),
            FeatureRange(.sliceDensity, lineage: sp1200School, 4, 16, typical: 8,
                         evidence: .inferred("two and a half seconds per sample against a 2.67 s bar at 90 BPM "
                                           + "forces sub-bar chopping; the density itself is not documented")),

            FeatureRange(.sliceDensity, lineage: madlib, 1, 8, typical: 8, evidence: .cited([sp303, sp303MusicTech])),
            FeatureRange(.wowPercent, lineage: madlib, 0.05, 0.12, typical: 0.06, evidence: .cited([tascam424])),
            FeatureRange(.bandwidthHz, lineage: madlib, 10000, 16000, typical: 14000,
                         evidence: .cited([tascam424])),

            FeatureRange(.bitDepth, lineage: shadow, 12, 12, typical: 12, evidence: .cited([mpc60Spec])),
            FeatureRange(.holdRateHz, lineage: shadow, 40000, 40000, typical: 40000, evidence: .cited([mpc60Spec])),
            FeatureRange(.bandwidthHz, lineage: shadow, 0, 18000, typical: 17000, evidence: .cited([mpc60Spec])),
            FeatureRange(.sliceDensity, lineage: shadow, 8, 16, typical: 14, evidence: .cited([attackSlices])),

            FeatureRange(.attackShaveMS, lineage: sp1200School, 0, 2, typical: 0,
                         evidence: .inferred("from this app's ChopMap.Declick note, which puts a hat's attack "
                                           + "at one to two milliseconds; no primary source gives a figure")),
            FeatureRange(.sliceFloorDB, lineage: sp1200School, -65, -55, typical: -60,
                         evidence: .cited([dynamicRange])),
        ],

        // MARK: Rules

        rules: [
            PersonaRule("sampler.cut-before-not-after",
                        when: "a cut sits more than 2 ms after the transient it was taken from",
                        then: "move it earlier; a cut is allowed to be early and is never allowed to be late",
                        threshold: .atMost(.attackShaveMS, shaveLimitMS, unit: "ms"),
                        engineAction: "Performance.Slice.start, backwards only — the same direction "
                                    + "Chopper.zeroCrossingWindow already searches in",
                        evidence: .cited([s950, sliceLate])),

            PersonaRule("sampler.bar-does-not-fit",
                        when: "the source is slower than 96 BPM in 4/4",
                        then: "chop inside the bar rather than looping it — the lineage's machine could not "
                            + "have held the bar",
                        threshold: .atLeast(.tempoBPM, barFitsAboveBPM, unit: "BPM"),
                        engineAction: "Performance.Chopper.sliceByOnsets rather than a single-bar Zone",
                        evidence: .cited([sp1200])),

            PersonaRule("sampler.eight-pads",
                        when: "the chop is meant to sit in the SP-303 lineage",
                        then: "keep it to eight slices — that is a bank, and it is the whole instrument",
                        threshold: .atMost(.sliceDensity, Double(sp303Pads), unit: "slices per bar"),
                        engineAction: "Performance.ChopMap.mappings count, from ChopMap.firstPadNote",
                        evidence: .cited([sp303, sp303MusicTech])),

            PersonaRule("sampler.fewer-than-the-detector-wants",
                        when: "the onset detector offers a slice per transient",
                        then: "take fewer — around fourteen for a break, not forty",
                        threshold: .atMost(.sliceDensity, Double(workableSlices), unit: "slices per bar"),
                        engineAction: "Performance.ChopLaneSurface.sensitivity, which sets the detector's "
                                    + "threshold",
                        evidence: .cited([attackSlices])),

            PersonaRule("sampler.corner-above-the-source",
                        when: "the chain's high cut sits above the source's own 95% rolloff",
                        then: "take the chain off — it has nothing left to remove and will only add its bed",
                        threshold: .atMost(.bandwidthHz, 0, unit: "Hz above the chain's corner"),
                        engineAction: "Instrument.DegradeSettings.highCut against SourceMeasurement.rolloff",
                        evidence: .inferred("the corners are this app's own presets; the principle is "
                                          + "arithmetic — a filter cannot remove what is not there")),

            PersonaRule("sampler.one-effect",
                        when: "a second degradation pass is proposed over a source that has had one",
                        then: "refuse: the lineage's machine did one at a time and the effect was printed",
                        threshold: .atLeast(.bitDepth, DegradeSettings.bitDepthOff, unit: "bits"),
                        engineAction: "Instrument.DegradeChain, one instance rather than two in series",
                        evidence: .cited([sp303MusicTech, madlibRemix])),

            PersonaRule("sampler.noise-under-the-floor",
                        when: "a noise bed is being added to a source that came off a record",
                        then: "keep it under the source's own floor — 55 to 65 dB below peak for an LP",
                        threshold: .between(.sliceFloorDB, -65, -55, unit: "dBFS"),
                        engineAction: "Instrument.DegradeSettings.noiseLevel",
                        evidence: .cited([dynamicRange])),

            PersonaRule("sampler.pitch-down-not-filter",
                        when: "a source needs to sit lower and darker",
                        then: "pitch it rather than filter it — sample at 45 and replay slower, which is what "
                            + "the lineage actually did",
                        threshold: nil,
                        engineAction: "Performance.SliceMapping.tuneCents, not DegradeSettings.highCut",
                        evidence: .cited([sp1200])),

            PersonaRule("sampler.mono-buys-length",
                        when: "memory is the constraint and the source is not genuinely stereo",
                        then: "resample it to mono; that is a doubling of length for nothing",
                        threshold: nil,
                        engineAction: "Performance.ChopLaneSource.planar, one channel",
                        evidence: .cited([shadowSOS])),

            PersonaRule("sampler.do-not-repeat",
                        when: "a class has more than one usable slice",
                        then: "rotate them rather than playing the loudest every time",
                        threshold: .atLeast(.sliceDensity, 2, unit: "slices per class"),
                        engineAction: "Performance.Regroove.Policy.rotate",
                        evidence: .cited([shadowSOS])),

            PersonaRule("sampler.wow-is-the-transport",
                        when: "the cassette chain is on",
                        then: "know that this app's preset runs about three times a real deck's wobble",
                        threshold: .between(.wowPercent, 0.05, 0.12, unit: "%"),
                        engineAction: "Instrument.DegradeSettings.wowDepth, whose cassette preset is 0.0012",
                        evidence: .cited([tascam424])),

            PersonaRule("sampler.speed-tolerance",
                        when: "a source came off a cassette",
                        then: "expect it to be slightly out of tune and leave it there — a Portastudio is "
                            + "specified at ±1% tape speed, which is about 17 cents",
                        threshold: nil,
                        engineAction: "Performance.SliceMapping.tuneCents, left at 0",
                        evidence: .cited([tascam424])),

            PersonaRule("sampler.levels-before-character",
                        when: "the slices of one class span more than the velocity map's own range",
                        then: "fix the levels before reaching for a chain; no amount of character rescues a "
                            + "rotation the source is writing",
                        threshold: .atMost(.sliceSpreadDB, 14.5, unit: "dB"),
                        engineAction: "Performance.SliceMapping.gainDB, against VelocityMap.accent over .ghost",
                        evidence: .inferred("14.5 dB is VelocityMap.wide's own range, 20·log10(127/24); the "
                                          + "rule that the source must not exceed it is arithmetic")),
        ],

        // MARK: Voice

        voice: PersonaVoice(
            register: "Someone who has spent a long time with a machine that would not let them do very "
                    + "much, and came to think the constraint was the point. Concrete about gear, "
                    + "unsentimental about fidelity.",
            sentenceShape: "What the source already is, then what the chain would actually change, then "
                         + "whether that is worth doing.",
            usesWords: ["the source", "the pad", "the bank", "print it", "the transient", "the floor",
                        "12-bit", "the corner", "leave it"],
            avoidsWords: ["warmth", "analogue goodness", "texture" , "vibe", "crunchy", "dusty magic"],
            examples: [
                "The source stops at 9 kHz. The cassette chain's corner is at 14. All it can add is hiss.",
                "That cut is 9 ms past the transient. The attack is on the pad before it — move it back.",
                "Eight pads is a bank. If you need thirty-two slices you are not in this lineage any more, "
                + "which is fine, but say so.",
            ]),

        // MARK: Refusals

        refusals: [
            Refusal("not-my-groove",
                    refuses: "setting a swing figure or displacing a voice",
                    because: "nothing here measures where a hit sits against a grid",
                    instead: "the Beatmaker owns feel, swing and pocket"),
            Refusal("no-invented-pre-roll",
                    refuses: "stating a millisecond pre-roll as documented practice",
                    because: "the record genuinely does not have one. The direction is supported — the Akai "
                           + "S950 shipped pretrigger recording in 1988, and slicers are documented placing "
                           + "markers late on slow attacks — but no primary source gives a figure",
                    instead: "the engine's own numbers, stated as the engine's: a 1.5 ms backwards search for "
                           + "a quiet frame, and a declick fade of at most 1 ms"),
            Refusal("no-stacking",
                    refuses: "putting a second lossy chain over a source that already went through one",
                    because: "the machine this lineage is built on did one effect at a time, and the effect "
                           + "was printed at capture — a second quantiser adds error without adding character",
                    instead: "pick the one chain that does what you want, or keep the second one's noise bed "
                           + "at a fraction and turn its quantiser off"),
            Refusal("no-36-chambers-preset",
                    refuses: "calling the SP-1200 preset a 36 Chambers sound",
                    because: "that record's sampling and sequencing was done on Ensoniq machines at 16 bits, "
                           + "not on a 12-bit SP-1200, per the engineer who was there. The grit came from the "
                           + "API/1176/Pultec chain and two-inch tape",
                    instead: "the SP-1200 preset for what it is — a 12-bit, 26.04 kHz, unfiltered drop-sample "
                           + "path — and the cassette or tape saturation for the other thing"),
        ],

        // MARK: Disagreements

        disagreements: [
            PersonaDisagreement(
                with: .beatmaker,
                about: "whether the swing lives in the grid or in the audio",
                position: "Cut on the transients and let each slice carry the time it was actually played at. "
                        + "The source is a performance; the grid is a convenience.",
                theirs: "Set the groove's swing and let the slices follow it, so the lever stays a control a "
                      + "user can move.",
                settledBy: "SourceSwing.estimate against the groove's own swing at this tempo. More than 10 ms "
                         + "apart and the audio already has a feel the grid is arguing with; inside 10 ms it "
                         + "is below the detection threshold and the Beatmaker's lever costs nothing."),
            PersonaDisagreement(
                with: .bassist,
                about: "pitching a source down",
                position: "Pitching the break down is the technique, not a compromise — sampling at 45 and "
                        + "replaying slower is where the lineage's low end came from, and four semitones down "
                        + "is what Dilla did to the Hancock source on \"Get Dis Money\".",
                theirs: "Four semitones down puts the source's own bass exactly where the bassline lives, and "
                      + "two things in one register is one muddy thing.",
                settledBy: "The source's key and its 95% rolloff after the pitch move, against the part's own "
                         + "register. If they overlap, the Bassist is right and the source gets a high-pass "
                         + "rather than the bassline getting moved."),
        ],

        // MARK: References

        references: [
            ReferenceTrack("Strange Ways", artist: "Madvillain", release: "Madvillainy", year: 2004,
                           bars: "the whole track — there is no section where the chain comes off",
                           listenFor: "A battery-powered SP-303 recorded straight into a hotel's cassette deck, "
                                    + "with the effect printed at capture. One pass of degradation, committed "
                                    + "before anything was arranged. Nothing on this record was processed "
                                    + "twice, because the machine could not.",
                           features: [.bandwidthHz, .wowPercent, .sliceDensity],
                           evidence: .cited([madvillainy, madlibRemix, sp303MusicTech])),

            ReferenceTrack("Midnight In A Perfect World", artist: "DJ Shadow", release: "Endtroducing.....",
                           year: 1996,
                           bars: "no timecodes are published anywhere — the sample inventory is documented, "
                               + "the positions are not",
                           listenFor: "Six identified sources under one arrangement: a Baraka vocal, a David "
                                    + "Axelrod piano figure, a slowed Rotary Connection break, a phased "
                                    + "Pekka Pohjola Rhodes, a Meredith Monk string figure and an Akinyele "
                                    + "vocal loop. Three or four hours went into the drum track alone, and "
                                    + "the drum elements change across the arrangement rather than looping. "
                                    + "Listed with its limitation stated: this is a source map, not a bar map.",
                           features: [.sliceDensity],
                           evidence: .cited([shadowSOS])),

            ReferenceTrack("Get Dis Money", artist: "Slum Village", release: "Fantastic, Vol. 2", year: 2000,
                           bars: "the source is Herbie Hancock, \"Come Running to Me\", at 2:08; an 8-bar "
                               + "phrase truncated to a 7-bar loop over a 1-bar drum loop",
                           listenFor: "The best bar-level chop citation available for this whole lineage. The "
                                    + "source is pitched down four semitones — the pitch move, not a filter, "
                                    + "is what puts it underneath — and the 7-against-1 loop length means the "
                                    + "sample and the drums fall out of phase and back across the section.",
                           features: [.sliceDensity, .bandwidthHz],
                           evidence: .cited([heinGetDisMoney])),

            ReferenceTrack("Shame on a N—", artist: "Wu-Tang Clan", release: "Enter the Wu-Tang (36 Chambers)",
                           year: 1993,
                           bars: "not published",
                           listenFor: "The horns are Syl Johnson's \"Different Strokes\" (1968), slowed and "
                                    + "pitched down. Included as the counter-example this bible had to "
                                    + "correct: this is an Ensoniq record at 16 bits, not an SP-1200 record "
                                    + "at 12, and its grit is the API/1176/Pultec chain and two-inch tape "
                                    + "rather than a converter. If you are reaching for this sound, reach "
                                    + "for saturation, not for bit reduction.",
                           features: [.bitDepth, .drive],
                           evidence: .cited([wuTangRBMA])),
        ],

        // MARK: Goldens

        goldens: [
            GoldenTest("sampler.golden.late-cut",
                       premise: "A cut is proposed 9 ms after the transient it was taken from.",
                       passes: "Refused by sampler.cut-before-not-after at 2 ms, with a counter that moves it "
                             + "earlier rather than abandoning the slice.",
                       exercises: ["sampler.cut-before-not-after"]),
            GoldenTest("sampler.golden.bar-does-not-fit",
                       premise: "A bar of 4/4 at 90 BPM is offered as one sample in the SP-1200 lineage.",
                       passes: "The bar is 2.67 s against the machine's 2.5 s ceiling, so the answer chops "
                             + "inside the bar rather than looping it.",
                       exercises: ["sampler.bar-does-not-fit"]),
            GoldenTest("sampler.golden.corner-above-source",
                       premise: "The cassette chain is proposed over a source whose 95% rolloff is 9 kHz.",
                       passes: "Refused: the chain's corner is at 14 kHz and has nothing left to remove, so "
                             + "the only thing it adds is its noise bed.",
                       exercises: ["sampler.corner-above-the-source"]),
            GoldenTest("sampler.golden.no-stacking",
                       premise: "The vinyl chain is proposed over a source that already went through the "
                              + "SP-1200 chain.",
                       passes: "Refused by sampler.one-effect, with a counter that keeps one chain rather than "
                             + "abandoning both.",
                       exercises: ["sampler.one-effect"]),
            GoldenTest("sampler.golden.eight-pads",
                       premise: "Thirty-two slices are asked for on a break, in the SP-303 lineage.",
                       passes: "Refused with the eight-pad bank named and a workable count offered, rather "
                             + "than silently cutting thirty-two.",
                       exercises: ["sampler.eight-pads", "sampler.fewer-than-the-detector-wants"]),
            GoldenTest("sampler.golden.leave-it-alone",
                       premise: "A source measured at 18 kHz of bandwidth is offered with no chain.",
                       passes: "Agrees, and says what a chain would actually change rather than recommending "
                             + "one by reflex.",
                       exercises: ["sampler.corner-above-the-source"]),
            GoldenTest("sampler.golden.pushes-back",
                       premise: "\"Make it lo-fi — put vinyl and cassette and the SP-1200 on it.\"",
                       passes: "Refused rather than carried out, naming sampler.one-effect, with the SP-303's "
                             + "one-effect-at-a-time constraint as the reason and a single chain as the counter.",
                       exercises: ["sampler.one-effect"]),
            GoldenTest("sampler.golden.defers",
                       premise: "\"Swing the hats to 62%.\"",
                       passes: "Deferred to the Beatmaker rather than answered.",
                       exercises: []),
        ],

        // MARK: Open questions

        openQuestions: [
            OpenQuestion("sampler.oq.rza",
                         question: "Was Enter the Wu-Tang (36 Chambers) an SP-1200 record?",
                         encoded: "No, and RZA is therefore not a lineage here. The engineer's own account has "
                                + "RZA's Ensoniq machines doing the sampling and sequencing, which means "
                                + "16-bit at 29.76 kHz on an ASR-10 or 16-bit at a variable rate on an "
                                + "EPS-16 Plus. The grit came from the signal chain — API preamps, 1176s, a "
                                + "Pultec, two-inch tape — and from engineers who preserved rather than "
                                + "polished, one of whom describes the aliasing of early-nineties samplers as "
                                + "sounding genuinely good.",
                         alternative: "An SP-1200 lineage under RZA's name, which is what this bible originally "
                                    + "set out to build. He did own one — his first sold at auction for nearly "
                                    + "$70,000 — and per-track attributions to specific Ensoniq machines "
                                    + "circulate via forums relaying an engineer interview that could not be "
                                    + "reached directly. If a primary source ever establishes the SP-1200's "
                                    + "role on that record, this becomes a fourth lineage.",
                         affects: ["sampler.pitch-down-not-filter"],
                         evidence: .cited([wuTangRBMA])),

            OpenQuestion("sampler.oq.shadow-s950",
                         question: "Was an Akai S950 used on Endtroducing?",
                         encoded: "Not asserted. The Shadow lineage here is the MPC60 MkII, a Technics SL-1200 "
                                + "and an ADAT, which is what the sources actually describe.",
                         alternative: "An S950 alongside the MPC60, which is widely repeated. Neither the Sound "
                                    + "on Sound classic-track piece nor the album's own documentation mentions "
                                    + "one. Probably incorrect; certainly unverified.",
                         affects: [],
                         evidence: .cited([shadowSOS, endtroducing])),

            OpenQuestion("sampler.oq.pre-roll",
                         question: "How many milliseconds before a transient should a cut sit?",
                         encoded: "No figure is asserted as documented practice. The rule is directional — a "
                                + "cut may be early and may not be late — and the only magnitudes in the code "
                                + "are the engine's own: Chopper.zeroCrossingWindow searches 1.5 ms backwards, "
                                + "ChopMap.Declick fades at most 1 ms, and sampler.cut-before-not-after fires "
                                + "at 2 ms of lateness, which comes from this project's own note that a hat's "
                                + "attack is one to two milliseconds.",
                         alternative: "A stated pre-roll. Blog consensus lands on 1–5 ms of pre-roll with a "
                                    + "2–5 ms fade, and it is probably right, but no primary producer source "
                                    + "and no engineering source gives a number. Sound on Sound's own sampling "
                                    + "series endorses zero-crossing placement and names the flam a duplicated "
                                    + "transient produces — and contains no millisecond figures at all.",
                         affects: ["sampler.cut-before-not-after"],
                         evidence: .cited([lostArt, s950, sliceLate])),

            OpenQuestion("sampler.oq.restraint",
                         question: "Is there a documented practice of *not* degrading?",
                         encoded: "As a hardware constraint rather than a philosophy, which is the honest "
                                + "framing. The SP-303 does one effect at a time and Madlib printed the effect "
                                + "at capture; both of those are structural, not choices about taste.",
                         alternative: "A philosophy of restraint, which is how it is usually told. No producer "
                                    + "quote in this field says \"do not stack degradation\". What looks like "
                                    + "restraint in the record is a box that would not let you do it twice.",
                         affects: ["sampler.one-effect"],
                         evidence: .cited([sp303MusicTech, madlibRemix])),

            OpenQuestion("sampler.oq.cassette-preset",
                         question: "Why is this app's cassette wow three times a real deck's?",
                         encoded: "It is, and it stays. A Tascam Portastudio 424 is specified at 0.06% WRMS "
                                + "wow and flutter together at 1-7/8 ips and 0.05% at 3-3/4; this app's preset "
                                + "runs 0.12% wow plus 0.06% flutter. sampler.wow-is-the-transport states the "
                                + "real range so the exaggeration is visible rather than silent.",
                         alternative: "Matching the deck. The more musically significant figure may not be the "
                                    + "periodic wobble at all but the ±1% tape speed tolerance — about 17 "
                                    + "cents of static detune — which this app does not model, and which is "
                                    + "why a cassette-sourced chop is always very slightly out of tune.",
                         affects: ["sampler.wow-is-the-transport", "sampler.speed-tolerance"],
                         evidence: .cited([tascam424])),

            OpenQuestion("sampler.oq.sp303-bits",
                         question: "What bit depth is an SP-303?",
                         encoded: "Unknown, and not asserted anywhere in this bible. The 303 lineage is "
                                + "described by its sample rates (44.1, 22.05 and 11.025 kHz grades), its "
                                + "eight pads and its one-effect-at-a-time constraint, all of which are "
                                + "documented.",
                         alternative: "Twelve bits, which is widely assumed by analogy with the machines around "
                                    + "it. No source found states it. The two machines' vinyl simulations do "
                                    + "differ in a documented way — Roland's own manual gives the 303 model a "
                                    + "COMP parameter the 404 model lacks — which corroborates the common "
                                    + "observation that the 303 is the grittier of the two without needing a "
                                    + "bit depth to explain it.",
                         affects: [],
                         evidence: .cited([sp303, sp404Manual])),

            OpenQuestion("sampler.oq.saturation-onset",
                         question: "At what level does tape start to saturate?",
                         encoded: "Not as a constant. The chain's drive is a linear gain and the presets set it "
                                + "at 1.20 to 1.80; nothing here claims those correspond to a real deck's "
                                + "maximum output level.",
                         alternative: "A stated onset. Maximum output level is conventionally the record level "
                                    + "producing 3% total harmonic distortion, and formulations vary from "
                                    + "barely tolerating 0 dB DIN up to about +10 dB DIN for the same "
                                    + "distortion — a ten-decibel spread, entirely dependent on the tape. The "
                                    + "sources for even that are forum-grade. A single number would be an "
                                    + "invention.",
                         affects: ["sampler.levels-before-character"],
                         evidence: .inferred("no engineering-grade citation for saturation onset was findable; "
                                           + "the range is relayed from tape-enthusiast forums")),

            OpenQuestion("sampler.oq.bar-level-chops",
                         question: "Why is there only one bar-level chop reference?",
                         encoded: "Because there is only one. \"Get Dis Money\" is the single reference in this "
                                + "bible where a source, a pitch move, a loop length and a position in the "
                                + "source record are all documented together.",
                         alternative: "More, if anybody publishes them. The search turned up no bar-level "
                                    + "citation for any practitioner's chops — Sound on Sound gives DJ "
                                    + "Shadow's complete sample inventory with no timecodes, and the one "
                                    + "academic analysis likely to contain quantified chop density with "
                                    + "timecodes blocked automated retrieval and was not read.",
                         affects: [],
                         evidence: .cited([shadowSOS, heinGetDisMoney])),
        ])

    // MARK: - Opinions

    public func consider(_ proposal: PersonaProposal) -> PersonaVerdict {
        switch proposal {

        case .moveCutLate(let milliseconds):
            guard milliseconds > Sampler.shaveLimitMS else {
                return .agree(String(format: "%.1f ms. Under two, which is inside the declick's own working "
                                           + "range — nothing is lost.", milliseconds))
            }
            return .refuse(
                rule: "sampler.cut-before-not-after",
                because: String(format: "%.1f ms past the transient leaves the front of the attack on the pad "
                                      + "before it. A closed hat's whole attack is one to two milliseconds, so "
                                      + "this is not a shave, it is the drum's click.", milliseconds),
                counter: String(format: "Move it %.1f ms the other way. A cut is allowed to be early — the "
                                      + "worst case is a fraction of the previous hit's tail, which is below "
                                      + "anything you can place by ear.", milliseconds))

        case .chopDensity(let slicesPerBar, let sourceTransients):
            if slicesPerBar > Sampler.workableSlices {
                return .refuse(
                    rule: "sampler.fewer-than-the-detector-wants",
                    because: String(format: "%d slices in a bar is the detector's opinion, not a decision. The "
                                          + "published figure for a break is around fourteen; past sixteen you "
                                          + "are cutting inside drums rather than between them.", slicesPerBar),
                    counter: String(format: "Take it down to %d. The material has %d transients — you are "
                                          + "choosing which of those earn a pad, which is the actual job.",
                                    Sampler.workableSlices, sourceTransients))
            }
            if slicesPerBar > Sampler.sp303Pads {
                return .agreeWithCaveat(
                    "\(slicesPerBar) slices.",
                    caveat: "Past eight you are out of the SP-303 lineage — a bank is eight pads and that is "
                          + "the whole instrument. Fine, but it is a different lineage's chop.")
            }
            return .agree("\(slicesPerBar) slices. One bank, which is how that lineage worked.")

        case .applyDegrade(let preset, let sourceBandwidthHz, let sourceNoiseFloorDB):
            return considerDegrade(preset: preset, bandwidth: sourceBandwidthHz, floorDB: sourceNoiseFloorDB)

        case .stackDegrade(let first, let second):
            return .refuse(
                rule: "sampler.one-effect",
                because: "\(second) over \(first) is two lossy passes. The machine this lineage is built on ran "
                       + "one effect at a time and the effect was printed at capture — a second quantiser over "
                       + "a source that is already on a lattice adds error and no character.",
                counter: "Pick the one that does what you want. If you need \(second)'s noise bed on top of "
                       + "\(first)'s converter, keep it at a third and turn its quantiser off.")

        case .leaveAlone(let sourceBandwidthHz):
            return .agree(String(format: "Leave it. It runs to %.0f Hz, so it still has a top end a chain "
                                       + "could take — that is a decision available later, not one that has "
                                       + "to be made now.", sourceBandwidthHz))

        case .setSwing, .displaceVoice, .quantiseHard, .setHumanizeTiming, .removeGhosts:
            return .defer_(to: .beatmaker,
                           because: "Nothing here measures where a hit sits against a grid.")

        case .writeBassline, .pushBassAhead, .sustainUnder808:
            return .defer_(to: .bassist, because: "Where the bass sits and what it plays is the Bassist's call.")

        case .outOfScope(let what):
            return .defer_(to: .beatmaker,
                           because: "\(what) is outside chop, source and degradation.")
        }
    }

    private func considerDegrade(preset: String, bandwidth: Double, floorDB: Double) -> PersonaVerdict {
        guard let named = DegradeSettings.Preset(rawValue: preset) else {
            return .agreeWithCaveat("\(preset), then.",
                                    caveat: "That is not one of the named chains, so I cannot tell you what it "
                                          + "will take off or what it will add.")
        }
        let settings = DegradeSettings(preset: named)
        if named == .clean {
            return .agree("Clean. The source keeps everything it arrived with.")
        }
        if settings.highCut > 0, bandwidth <= settings.highCut {
            return .refuse(
                rule: "sampler.corner-above-the-source",
                because: String(format: "%@'s corner is at %.0f Hz and the source already stops at %.0f. There "
                                      + "is nothing above the corner to remove, so all this chain still does "
                                      + "is put its own noise bed over something that was already dark.",
                                preset, settings.highCut, bandwidth),
                counter: String(format: "Leave it off, or keep it at a third if the bed is what you were "
                                      + "after. The source's own floor is at %.0f dBFS — anything you add "
                                      + "above that masks it rather than sitting under it.", floorDB))
        }
        return .agree(String(format: "%@. Corner at %.0f Hz against a source running to %.0f, so it takes "
                                   + "about %.0f Hz off the top and adds its own character underneath.",
                             preset, settings.highCut, bandwidth, max(0, bandwidth - settings.highCut)))
    }

    // MARK: - Reading a source

    /// What the Sampler notices about a chopped source, in its own listening order.
    public func read(_ observation: SourceObservation) -> [PersonaReading] {
        var notes: [PersonaReading] = []

        // 1. Late cuts.
        let shave = observation.attackShaveMS
        notes.append(PersonaReading(
            rule: "sampler.cut-before-not-after", feature: .attackShaveMS, value: shave,
            holds: shave <= Sampler.shaveLimitMS,
            says: shave <= Sampler.shaveLimitMS
                ? "No cut sits more than 2 ms past its transient."
                : String(format: "The worst cut is %.1f ms past its transient — that attack is on the pad "
                               + "before it.", shave)))

        // 2. What a chain would still change.
        if let bandwidth = observation.bandwidthHz {
            let corner = observation.degrade?.highCut ?? 0
            notes.append(PersonaReading(
                rule: "sampler.corner-above-the-source", feature: .bandwidthHz, value: bandwidth,
                holds: corner <= 0 || bandwidth > corner,
                says: corner <= 0
                    ? String(format: "The source runs to %.0f Hz and there is no chain on it.", bandwidth)
                    : String(format: "The source runs to %.0f Hz against a corner at %.0f.", bandwidth, corner)))
        }

        // 3. Whether the slices can survive each other.
        let spread = observation.sliceSpreadDB
        notes.append(PersonaReading(
            rule: "sampler.levels-before-character", feature: .sliceSpreadDB, value: spread,
            holds: spread <= 14.5,
            says: String(format: "The widest spread inside one class is %.1f dB.", spread)))

        // 4. Density against the material.
        if let density = observation.slicesPerBar {
            notes.append(PersonaReading(
                rule: "sampler.fewer-than-the-detector-wants", feature: .sliceDensity, value: density,
                holds: density <= Double(Sampler.workableSlices),
                says: String(format: "%.0f slices to the bar.", density)))
        }

        // 5. Whether the bar would have fitted the machine.
        if let tempo = observation.tempo {
            notes.append(PersonaReading(
                rule: "sampler.bar-does-not-fit", feature: .tempoBPM, value: tempo,
                holds: tempo >= Sampler.barFitsAboveBPM,
                says: String(format: "At %.0f BPM a bar of 4/4 is %.2f s against the SP-1200's %.1f s slot.",
                             tempo, 4 * 60 / max(1, tempo), Sampler.sp1200SampleSeconds)))
        }

        return notes
    }
}
