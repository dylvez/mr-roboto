import MusicTheory
import SongGraph

// The feels the genres added after the first thirty-three needed: big-band swing, ska, the dub
// and roots drummers' steppers and rockers, dancehall, new jack swing and the slow jam, a film
// score's tom ostinato, flamenco's rumba and bulerías, klezmer's bulgar and the Arabic saidi.
//
// Written for this app like the Latin and the style feels: each the skeleton the style's players
// and method books agree on, marked `original` because no step number is cited, with the
// provenance saying what each line stands for.
extension Feels {

    static let more: [Feel] = [
        bigBandSwing, ska, steppers, rockers, dancehall, newJackSwing, slowJam, cinematicToms,
        rumbaFlamenca, bulerias, bulgar, saidi,
    ]

    private static func written(_ summary: String, lineage: [String]) -> Provenance {
        Provenance(origin: .original, summary: summary, lineage: lineage)
    }

    /// The same steps in both bars of a two-bar, sixteen-step groove.
    private static func both(_ steps: [Int]) -> [Int] { steps + steps.map { $0 + 16 } }

    private static func twoBars(_ patterns: [GroovePattern], swing: Double = 0) -> Groove {
        Groove(stepsPerBar: 16, bars: 2, swing: swing, patterns: patterns)
    }

    // MARK: Swing

    /// Two bars on the triplet grid: three steps a beat.
    static let bigBandSwing = Feel(
        name: "Big Band Swing",
        idioms: [.swing, .jazz],
        tempoRange: 110...240, suggestedTempo: 160,
        groove: Groove(stepsPerBar: 12, bars: 2, swing: 0, patterns: [
            // Spang-a-lang: the beat, then the skip note on the last triplet of 2 and 4.
            line(.ride, steps: 24, beat: 3, on: [0, 3, 5, 6, 9, 11, 12, 15, 17, 18, 21, 23], accents: [3, 9, 15, 21]),
            line(.closedHat, steps: 24, beat: 3, on: [3, 9, 15, 21]),
            line(.snare, steps: 24, beat: 3, on: [23], ghosts: [5, 14, 20]),
            // Feathered: every beat, barely there.
            line(.kick, steps: 24, beat: 3, on: [], ghosts: [0, 3, 6, 9, 12, 15, 18, 21]),
        ]),
        velocities: .soft,
        humanize: Humanize(velocity: 0.1, timing: 0.05, seed: 0xB16B_0001),
        provenance: written("The ride's spang-a-lang with its skip note, the hi-hat closing on 2 and 4, the bass drum feathered on every beat under the band, the left hand comping on the snare and kicking the last triplet into the next bar.",
                            lineage: ["Jo Jones and the Basie band", "Mel Lewis"]))

    // MARK: Jamaica

    static let ska = Feel(
        name: "Ska",
        idioms: [.ska, .reggae],
        tempoRange: 110...160, suggestedTempo: 132,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: both([2, 6, 10, 14]), accents: both([2, 6, 10, 14])),
            line(.rim, steps: 32, beat: 4, on: both([4, 12])),
            line(.snare, steps: 32, beat: 4, on: [30], ghosts: [31]),
            line(.kick, steps: 32, beat: 4, on: both([0, 8])),
        ]),
        provenance: written("The hats on every off-beat, where the guitar and piano skank, the cross-stick on 2 and 4, the kick on 1 and 3, and a snare pickup into the next phrase.",
                            lineage: ["Lloyd Knibb and the Skatalites", "Studio One"]))

    /// The kick on every beat: the march of late-seventies roots and dub.
    static let steppers = Feel(
        name: "Steppers",
        idioms: [.dub, .reggae],
        tempoRange: 66...90, suggestedTempo: 76,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: both([0, 2, 4, 6, 8, 10, 12, 14]), ghosts: both([1, 5, 9, 13])),
            line(.openHat, steps: 32, beat: 4, on: [30]),
            line(.rim, steps: 32, beat: 4, on: both([8])),
            line(.kick, steps: 32, beat: 4, on: both([0, 4, 8, 12])),
        ]),
        provenance: written("Four on the floor at a roots tempo, the cross-stick still on 3 where the one drop puts it, eighth hats with sixteenth ghosts and an open hat to turn the phrase.",
                            lineage: ["Sly Dunbar", "Channel One", "Jah Shaka's sound system"]))

    /// The kick back on 1 and 3, the hats busy and opening on the off-beats.
    static let rockers = Feel(
        name: "Rockers",
        idioms: [.dub, .reggae],
        tempoRange: 68...92, suggestedTempo: 80,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: both([0, 4, 8, 12]), ghosts: both([1, 3, 5, 7, 9, 11, 13, 15])),
            line(.openHat, steps: 32, beat: 4, on: both([2, 6, 10, 14])),
            line(.snare, steps: 32, beat: 4, on: both([8]), ghosts: [27]),
            line(.kick, steps: 32, beat: 4, on: both([0, 8]), ghosts: [14]),
        ]),
        provenance: written("The kick on 1 and 3 with the snare on 3, the hats driving in sixteenths and opening on every off-beat — the Channel One sound that moved reggae off the one drop.",
                            lineage: ["Sly Dunbar and the Revolutionaries", "Channel One"]))

    /// The tresillo on the kick under a clap on 2 and 4.
    static let dancehall = Feel(
        name: "Dancehall",
        idioms: [.dancehall, .reggae],
        tempoRange: 85...110, suggestedTempo: 96,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: both([0, 2, 4, 6, 8, 10, 12, 14]), ghosts: both([7, 15])),
            line(.clap, steps: 32, beat: 4, on: both([4, 12])),
            line(.rim, steps: 32, beat: 4, on: both([3, 10]), ghosts: both([14])),
            line(.kick, steps: 32, beat: 4, on: both([0, 6, 12])),
        ]),
        provenance: written("The kick in three, three and two across the bar, a clap on 2 and 4 and a rim answering in the gaps: the digital riddim the deejay rides.",
                            lineage: ["King Jammy's \"Sleng Teng\"", "Steely & Clevie"]))

    // MARK: R&B

    static let newJackSwing = Feel(
        name: "New Jack Swing",
        idioms: [.rnb, .hipHop],
        tempoRange: 98...120, suggestedTempo: 108,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: all(upTo: 32), accents: both([0, 4, 8, 12])),
            line(.snare, steps: 32, beat: 4, on: both([4, 12]), ghosts: [15, 31]),
            line(.clap, steps: 32, beat: 4, on: both([4, 12])),
            line(.kick, steps: 32, beat: 4, on: [0, 3, 6, 10, 16, 19, 22, 25, 26]),
        ], swing: 0.45),
        provenance: written("Swung sixteenths on the hats, a snare and clap together on 2 and 4, and a kick that jumps around the beat: hip-hop's drum machine under soul's chords.",
                            lineage: ["Teddy Riley", "Bobby Brown", "Guy"]))

    static let slowJam = Feel(
        name: "Slow Jam",
        idioms: [.rnb, .ballad],
        tempoRange: 58...80, suggestedTempo: 66,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: both([0, 2, 4, 6, 8, 10, 12, 14]), ghosts: both([7, 11, 15])),
            line(.snare, steps: 32, beat: 4, on: both([4, 12])),
            line(.shaker, steps: 32, beat: 4, on: both([2, 6, 10, 14]), ghosts: both([0, 4, 8, 12])),
            line(.kick, steps: 32, beat: 4, on: [0, 7, 10, 16, 23, 26, 27]),
        ], swing: 0.3),
        provenance: written("A slow, swung backbeat: the snare on 2 and 4, eighth hats with sixteenth ghosts, a shaker on the off-beats and a kick that lands late in the bar.",
                            lineage: ["Jam & Lewis ballads", "Babyface", "Jodeci"]))

    // MARK: Film

    static let cinematicToms = Feel(
        name: "Cinematic Toms",
        idioms: [.cinematic],
        tempoRange: 80...150, suggestedTempo: 120,
        groove: twoBars([
            line(.lowTom, steps: 32, beat: 4, on: both([0, 2, 4, 6, 8, 10, 12, 14]), accents: both([0, 6, 12])),
            line(.midTom, steps: 32, beat: 4, on: both([3, 11]), ghosts: both([7])),
            line(.kick, steps: 32, beat: 4, on: both([0, 8])),
            line(.crash, steps: 32, beat: 4, on: [0]),
        ]),
        velocities: .standard,
        provenance: written("An eighth-note ostinato on the low toms accented three, three and two, the higher drum answering, the bass drum on 1 and 3: the drive under a trailer cue.",
                            lineage: ["trailer music", "Hans Zimmer's percussion ostinatos"]))

    // MARK: Flamenco

    static let rumbaFlamenca = Feel(
        name: "Rumba Flamenca",
        idioms: [.flamenco, .latin],
        tempoRange: 95...130, suggestedTempo: 112,
        groove: twoBars([
            line(.clap, steps: 32, beat: 4, on: both([2, 6, 10, 14])),
            line(.cajonSlap, steps: 32, beat: 4, on: both([4, 12]), ghosts: both([2, 10, 15])),
            line(.cajon, steps: 32, beat: 4, on: both([0, 6, 8, 14])),
            line(.shaker, steps: 32, beat: 4, on: all(upTo: 32), ghosts: both([1, 3, 5, 7, 9, 11, 13, 15])),
        ]),
        provenance: written("The rumba's strum on the cajón — the bass tone on 1, the and of 2, 3 and the and of 4 — its slap on 2 and 4, palmas on every off-beat.",
                            lineage: ["Peret", "Paco de Lucía's rumbas", "Gipsy Kings"]))

    /// The twelve-beat compás, one step a beat, counted from twelve.
    static let bulerias = Feel(
        name: "Bulerías",
        idioms: [.flamenco],
        tempoRange: 180...270, suggestedTempo: 220,
        timeSignature: TimeSignature(12, 8),
        groove: Groove(stepsPerBar: 12, bars: 1, swing: 0, patterns: [
            // Palmas on every beat, the accents on 3, 6, 8, 10 and 12.
            line(.clap, steps: 12, beat: 3, on: all(upTo: 12), accents: [2, 5, 7, 9, 11]),
            line(.cajonSlap, steps: 12, beat: 3, on: [2, 5, 7, 9, 11]),
            line(.cajon, steps: 12, beat: 3, on: [11, 5]),
        ]),
        humanize: Humanize(velocity: 0.12, timing: 0.04, seed: 0xB0E1_0001),
        provenance: written("Twelve beats with the weight on 3, 6, 8, 10 and 12: palmas on every one and louder on those, the cajón's slap with them and its bass on 6 and 12.",
                            lineage: ["Jerez", "the compás of bulerías"]))

    // MARK: Klezmer

    static let bulgar = Feel(
        name: "Bulgar",
        idioms: [.klezmer, .folk],
        tempoRange: 108...144, suggestedTempo: 126,
        groove: twoBars([
            line(.kick, steps: 32, beat: 4, on: both([0, 6, 12])),
            line(.ride, steps: 32, beat: 4, on: both([0, 6, 12])),
            line(.snare, steps: 32, beat: 4, on: both([4, 10, 14]), ghosts: both([2, 8])),
        ]),
        provenance: written("The poyk — a bass drum with a cymbal on it — in three, three and two across the bar, the snare filling the gaps: the bulgar's lilt under the clarinet.",
                            lineage: ["Dave Tarras", "Abe Schwartz's orchestra"]))

    // MARK: Arabic

    /// Saidi: doum, tek, rest, doum, doum, rest, tek, rest.
    static let saidi = Feel(
        name: "Saidi",
        idioms: [.middleEastern],
        tempoRange: 85...125, suggestedTempo: 104,
        groove: twoBars([
            line(.darbuka, steps: 32, beat: 4, on: both([0, 6, 8]), accents: both([0, 8])),
            line(.darbukaTek, steps: 32, beat: 4, on: both([2, 12]), ghosts: both([4, 10, 14])),
            line(.frameDrum, steps: 32, beat: 4, on: both([6, 8])),
            line(.tambourine, steps: 32, beat: 4, on: both([2, 12])),
        ]),
        humanize: Humanize(velocity: 0.1, timing: 0.04, seed: 0x5A1D_0001),
        provenance: written("The saidi of Upper Egypt: two doums together in the middle of the bar where the maqsum has one, the teks at the rim and the riq's jingles with them, the frame drum under the doubled doum.",
                            lineage: ["Upper Egyptian folk", "the stick dance"]))
}
