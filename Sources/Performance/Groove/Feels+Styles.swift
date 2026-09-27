import MusicTheory
import SongGraph

// Styles the library had nothing for: dance music from disco to drum & bass, the Afro and
// Caribbean-descended grooves, New Orleans, drill, funk, gospel and country, and the meters past
// 4/4 and 3/4 — a slow 12/8, a 6/8 bell, 5/4 and 7/8.
//
// Written for this app, like the Latin feels: each is the skeleton the style's players and method
// books agree on, marked `original` because no step number is cited, with the provenance saying
// what each line stands for so a persona — or a player who knows better — can argue with it. Hand
// parts go on the kit's hand percussion (`SynthMachine+Percussion.swift`).
//
// Tempo is in the song's beats. In 6/8, 7/8 and 12/8 the beat is the eighth note, as the song's
// meter and the MIDI export count it, so those tempos read about three times the dotted-quarter
// pulse a player would count.
extension Feels {

    static let styles: [Feel] = [
        disco, classicHouse, ukGarage, drumAndBass, halftime, jerseyClub,
        afrobeats, amapiano, afrobeat, secondLine, ukDrill, funkOneChord, gospelShout, countryTwoStep,
        slowBlues128, afroCuban68, fiveFour, sevenEight,
    ]

    private static func written(_ summary: String, lineage: [String]) -> Provenance {
        Provenance(origin: .original, summary: summary, lineage: lineage)
    }

    /// The same steps in both bars of a two-bar, sixteen-step groove.
    private static func both(_ steps: [Int]) -> [Int] { steps + steps.map { $0 + 16 } }

    private static func twoBars(_ patterns: [GroovePattern], swing: Double = 0) -> Groove {
        Groove(stepsPerBar: 16, bars: 2, swing: swing, patterns: patterns)
    }

    // MARK: Dance

    static let disco = Feel(
        name: "Disco",
        idioms: [.disco, .funk],
        tempoRange: 108...128, suggestedTempo: 118,
        groove: twoBars([
            line(.openHat, steps: 32, beat: 4, on: both([2, 6, 10, 14]), accents: both([2, 6, 10, 14])),
            line(.closedHat, steps: 32, beat: 4, on: both([0, 4, 8, 12]), ghosts: both([1, 3, 5, 7, 9, 11, 13, 15])),
            line(.tambourine, steps: 32, beat: 4, on: both([4, 12]), ghosts: both([2, 6, 10, 14])),
            line(.snare, steps: 32, beat: 4, on: both([4, 12])),
            line(.kick, steps: 32, beat: 4, on: both([0, 4, 8, 12])),
        ]),
        humanize: Humanize(velocity: 0.1, timing: 0.04, seed: 0xD15C_0001),
        provenance: written("Kick on every beat, the open hat on every 'and' — the disco pea-soup — sixteenth hats between, the snare and a tambourine on 2 and 4.",
                            lineage: ["Earl Young", "Philadelphia International", "Chic"]))

    static let classicHouse = Feel(
        name: "Classic House",
        idioms: [.house, .electronic],
        tempoRange: 118...128, suggestedTempo: 123,
        groove: twoBars([
            line(.openHat, steps: 32, beat: 4, on: both([2, 6, 10, 14])),
            line(.shaker, steps: 32, beat: 4, on: both([2, 6, 10, 14]), ghosts: both([0, 1, 3, 4, 5, 7, 8, 9, 11, 12, 13, 15])),
            line(.clap, steps: 32, beat: 4, on: both([4, 12])),
            line(.kick, steps: 32, beat: 4, on: both([0, 4, 8, 12])),
        ], swing: Swing(percent: 54).factor),
        voices: [.shaker: VoiceFeel(humanizeScale: 1.5)],
        provenance: written("A 909 four on the floor with claps on 2 and 4, the open hat on the off-beats, and a shaker running sixteenths — no snare, a touch of swing.",
                            lineage: ["Frankie Knuckles", "Larry Heard", "Chicago house", "the TR-909"]))

    static let ukGarage = Feel(
        name: "UK Garage 2-Step",
        idioms: [Idiom("uk-garage"), .electronic],
        tempoRange: 128...138, suggestedTempo: 132,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: both([2, 6, 10, 14]), ghosts: both([3, 7, 11, 15])),
            line(.rim, steps: 32, beat: 4, on: [], ghosts: [9, 25, 27]),
            line(.clap, steps: 32, beat: 4, on: both([4, 12])),
            line(.kick, steps: 32, beat: 4, on: [0, 10, 16, 23, 26]),
        ], swing: Swing(percent: 60).factor),
        provenance: written("Two-step: the kick skips beat 3 and lands around it, claps on 2 and 4, hats swung hard on the 'and's with a ghost after each.",
                            lineage: ["Todd Edwards", "MJ Cole", "Artful Dodger"]))

    static let drumAndBass = Feel(
        name: "Drum & Bass",
        idioms: [.drumAndBass, .electronic],
        tempoRange: 165...178, suggestedTempo: 174,
        groove: twoBars([
            line(.ride, steps: 32, beat: 4, on: eighths(upTo: 32), accents: both([2, 6, 10, 14])),
            line(.snare, steps: 32, beat: 4, on: both([4, 12]), ghosts: [7, 15, 23, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 10, 16, 26, 27]),
        ]),
        humanize: Humanize(velocity: 0.08, timing: 0.02, seed: 0xD4B_0001),
        provenance: written("The two-step at 174: kick on 1 and the 'and' of 3, snare on 2 and 4 with ghosts between, a ride on the eighths.",
                            lineage: ["Goldie", "Roni Size", "LTJ Bukem"]))

    static let halftime = Feel(
        name: "Halftime",
        idioms: [Idiom("dubstep"), .electronic],
        tempoRange: 136...150, suggestedTempo: 140,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32), ghosts: [7, 15, 23, 31]),
            line(.openHat, steps: 32, beat: 4, on: [14]),
            line(.snare, steps: 32, beat: 4, on: both([8])),
            line(.kick, steps: 32, beat: 4, on: [0, 19, 22]),
        ]),
        provenance: written("Half-time: at 140 the snare lands only on beat 3, so it feels like 70; a lone kick on 1, a late kick answer in bar two, hats on the eighths.",
                            lineage: ["Skream", "Benga", "Burial"]))

    static let jerseyClub = Feel(
        name: "Jersey Club",
        idioms: [Idiom("jersey-club"), .electronic, .hipHop],
        tempoRange: 130...145, suggestedTempo: 140,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.clap, steps: 32, beat: 4, on: both([4, 12]), ghosts: [30]),
            line(.kick, steps: 32, beat: 4, on: both([0, 4, 8, 10, 14])),
        ]),
        provenance: written("The Jersey club kick: 1, 2, 3, the 'and' of 3 and the 'and' of 4 — the bounce — under claps on 2 and 4.",
                            lineage: ["DJ Tameil", "DJ Sliink", "Newark club"]))

    // MARK: Afro and Caribbean

    static let afrobeats = Feel(
        name: "Afrobeats",
        idioms: [Idiom("afrobeats"), .pop],
        tempoRange: 98...118, suggestedTempo: 106,
        groove: twoBars([
            line(.shaker, steps: 32, beat: 4, on: both([2, 6, 10, 14]), ghosts: both([0, 1, 3, 4, 5, 7, 8, 9, 11, 12, 13, 15])),
            line(.rim, steps: 32, beat: 4, on: both([3, 10])),
            line(.clap, steps: 32, beat: 4, on: both([12])),
            line(.highConga, steps: 32, beat: 4, on: both([7, 14]), ghosts: both([6])),
            line(.lowConga, steps: 32, beat: 4, on: both([15])),
            line(.kick, steps: 32, beat: 4, on: both([0, 6, 8])),
        ], swing: Swing(percent: 56).factor),
        humanize: Humanize(velocity: 0.12, timing: 0.05, seed: 0xAF80_0001),
        provenance: written("The tresillo under it all — kick on 1, the 'and' of 2 and 3 — a rim answering on the 'a' of 1 and the 'and' of 3, a clap on 4, congas and a shaker in lightly swung sixteenths.",
                            lineage: ["Wizkid", "Burna Boy", "Davido", "P-Square"]))

    static let amapiano = Feel(
        name: "Amapiano",
        idioms: [Idiom("amapiano"), .house],
        tempoRange: 108...116, suggestedTempo: 112,
        groove: twoBars([
            line(.shaker, steps: 32, beat: 4, on: both([2, 6, 10, 14]), ghosts: both([0, 1, 3, 4, 5, 7, 8, 9, 11, 12, 13, 15])),
            line(.woodblock, steps: 32, beat: 4, on: both([3, 11]), ghosts: both([6, 14])),
            line(.openHat, steps: 32, beat: 4, on: both([14])),
            line(.clap, steps: 32, beat: 4, on: both([4, 12]), ghosts: [29]),
            line(.kick, steps: 32, beat: 4, on: both([0, 8])),
        ], swing: Swing(percent: 57).factor),
        humanize: Humanize(velocity: 0.12, timing: 0.04, seed: 0xA3A_0001),
        provenance: written("Slow house with the kick on 1 and 3 only, claps on 2 and 4, a swung shaker, and wooden hits in the gaps — the space the log drum bass plays into.",
                            lineage: ["Kabza De Small", "DJ Maphorisa", "Kelvin Momo"]))

    static let afrobeat = Feel(
        name: "Afrobeat",
        idioms: [Idiom("afrobeat"), .funk],
        tempoRange: 100...124, suggestedTempo: 112,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: all(upTo: 32), accents: both([2, 6, 10, 14])),
            line(.openHat, steps: 32, beat: 4, on: [30]),
            line(.cowbell, steps: 32, beat: 4, on: [0, 3, 6, 10, 12, 16, 19, 22, 26, 28]),
            line(.snare, steps: 32, beat: 4, on: both([4]), ghosts: [7, 9, 13, 23, 25, 29]),
            line(.kick, steps: 32, beat: 4, on: [0, 3, 10, 16, 19, 24, 27]),
        ]),
        humanize: Humanize(velocity: 0.15, timing: 0.05, seed: 0xFE1A_0001),
        provenance: written("Hats in sixteenths leaning on the 'and's, a bell line, a snare that talks in ghost notes more than it backbeats, and a kick that never sits on 3 — the Tony Allen engine.",
                            lineage: ["Tony Allen", "Fela Kuti and Africa 70"]))

    static let secondLine = Feel(
        name: "Second Line",
        idioms: [Idiom("new-orleans"), .funk],
        tempoRange: 90...110, suggestedTempo: 98,
        groove: twoBars([
            line(.snare, steps: 32, beat: 4, on: [4, 6, 12, 14, 20, 22, 28, 30], ghosts: [1, 3, 9, 11, 17, 19, 25, 27],
                 accents: [6, 14, 22, 30]),
            line(.cowbell, steps: 32, beat: 4, on: both([0, 4, 8, 12])),
            line(.kick, steps: 32, beat: 4, on: [0, 6, 8, 16, 22, 27]),
            line(.crash, steps: 32, beat: 4, on: [0]),
        ], swing: Swing(percent: 60).factor),
        humanize: Humanize(velocity: 0.15, timing: 0.06, seed: 0x2D11_0001),
        provenance: written("A brass-band parade beat on a kit: the bass drum's push on the 'and' of 2, a snare full of ghost notes accenting the 'and's, a bell on the quarters, all swung.",
                            lineage: ["New Orleans brass bands", "Zigaboo Modeliste", "Johnny Vidacovich"]))

    // MARK: Hip-hop, funk, gospel, country

    static let ukDrill = Feel(
        name: "UK Drill",
        idioms: [Idiom("drill"), .hipHop, .trap],
        tempoRange: 138...146, suggestedTempo: 142,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: [0, 3, 6, 8, 11, 14, 16, 19, 22, 24, 26, 27, 30]),
            line(.snare, steps: 32, beat: 4, on: [8, 24], ghosts: [13, 31]),
            line(.kick, steps: 32, beat: 4, on: [0, 5, 11, 18, 21, 27]),
        ]),
        humanize: Humanize(velocity: 0.08, timing: 0.02, seed: 0xD217_0001),
        provenance: written("Half-time at 142 with the snare on 3 and a late ghost pulling it around, hats in threes against the beat, and a kick that slides like the 808 bass under it.",
                            lineage: ["67", "Headie One", "Pop Smoke's Brooklyn drill"]))

    static let funkOneChord = Feel(
        name: "One-Chord Funk",
        idioms: [.funk, .soul],
        tempoRange: 96...116, suggestedTempo: 104,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: all(upTo: 32), accents: both([0, 4, 8, 12])),
            line(.openHat, steps: 32, beat: 4, on: [14]),
            line(.snare, steps: 32, beat: 4, on: both([4, 12]), ghosts: [7, 9, 15, 23, 25, 29, 31]),
            line(.kick, steps: 32, beat: 4, on: [0, 2, 10, 16, 19, 26]),
        ]),
        humanize: Humanize(velocity: 0.12, timing: 0.03, seed: 0xF0C4_0001),
        provenance: written("James Brown's 'on the one': the downbeat hit hard and doubled, a backbeat surrounded by ghost notes, sixteenth hats, the kick answering the bass.",
                            lineage: ["Clyde Stubblefield", "Jabo Starks", "the JBs"]))

    static let gospelShout = Feel(
        name: "Gospel Shout",
        idioms: [Idiom("gospel"), .soul],
        tempoRange: 120...150, suggestedTempo: 132,
        groove: twoBars([
            line(.tambourine, steps: 32, beat: 4, on: eighths(upTo: 32), accents: both([4, 12])),
            line(.closedHat, steps: 32, beat: 4, on: both([0, 4, 8, 12]), ghosts: both([2, 6, 10, 14])),
            line(.snare, steps: 32, beat: 4, on: both([4, 12]), ghosts: [3, 11, 19, 27]),
            line(.kick, steps: 32, beat: 4, on: both([0, 6, 8, 14])),
        ], swing: Swing(percent: 64).factor),
        humanize: Humanize(velocity: 0.12, timing: 0.04, seed: 0x6057_0001),
        provenance: written("The shout: a swung, driving backbeat with a tambourine on every eighth, the kick pushing the 'and's, a ghost before each snare.",
                            lineage: ["COGIC shout music", "the church drummer's pocket"]))

    static let countryTwoStep = Feel(
        name: "Country Two-Step",
        idioms: [.country, .folk],
        tempoRange: 100...140, suggestedTempo: 118,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.rim, steps: 32, beat: 4, on: both([4, 12])),
            line(.kick, steps: 32, beat: 4, on: both([0, 8])),
        ], swing: Swing(percent: 55).factor),
        velocities: .soft,
        provenance: written("Boom-chick: kick on 1 and 3 with the bass, a cross-stick on 2 and 4, eighth hats with a little shuffle.",
                            lineage: ["Buck Owens", "the Bakersfield sound"]))

    // MARK: Meters

    /// 12/8, one step per eighth, the beat the eighth note.
    static let slowBlues128 = Feel(
        name: "Slow Blues 12/8",
        idioms: [.blues, .soul],
        tempoRange: 140...195, suggestedTempo: 165,
        timeSignature: TimeSignature(12, 8),
        groove: Groove(stepsPerBar: 12, bars: 1, swing: 0, patterns: [
            line(.ride, steps: 12, beat: 3, on: all(upTo: 12)),
            line(.snare, steps: 12, beat: 3, on: [3, 9], ghosts: [11]),
            line(.kick, steps: 12, beat: 3, on: [0, 5, 6]),
        ]),
        velocities: .soft,
        humanize: Humanize(velocity: 0.1, timing: 0.04, seed: 0x1208_0001),
        provenance: written("Four dotted-quarter beats each split in three: a ride on every eighth, the snare on 2 and 4, the kick on 1 and pushing into 3.",
                            lineage: ["\"Stormy Monday\"", "B.B. King", "Otis Redding's ballads"]))

    /// 6/8, one step per eighth: the standard bell over two bars, the beat the eighth note.
    static let afroCuban68 = Feel(
        name: "Afro-Cuban 6/8",
        idioms: [.latin, Idiom("afro-cuban")],
        tempoRange: 180...300, suggestedTempo: 240,
        timeSignature: .sixEight,
        groove: Groove(stepsPerBar: 6, bars: 2, swing: 0, patterns: [
            line(.cowbell, steps: 12, beat: 3, on: [0, 2, 4, 5, 7, 9, 11], accents: [0, 2, 4, 5, 7, 9, 11]),
            line(.shaker, steps: 12, beat: 3, on: [0, 3, 6, 9], ghosts: [1, 2, 4, 5, 7, 8, 10, 11]),
            line(.highConga, steps: 12, beat: 3, on: [3, 4, 9, 10]),
            line(.lowConga, steps: 12, beat: 3, on: [5, 11]),
            line(.kick, steps: 12, beat: 3, on: [0, 6]),
        ]),
        humanize: Humanize(velocity: 0.12, timing: 0.04, seed: 0x68_0001),
        provenance: written("The standard bell — the seven-stroke 12/8 pattern — over two bars of 6/8, a shaker on the eighths, conga tones answering, the kick on each dotted-quarter downbeat.",
                            lineage: ["bembé", "Yoruba bell patterns", "Afro-Cuban jazz"]))

    static let fiveFour = Feel(
        name: "Five Four",
        idioms: [.jazz, .rock],
        tempoRange: 110...180, suggestedTempo: 170,
        timeSignature: TimeSignature(5, 4),
        groove: Groove(stepsPerBar: 20, bars: 1, swing: Swing(percent: 62).factor, patterns: [
            line(.ride, steps: 20, beat: 4, on: [0, 4, 6, 8, 12, 16, 18]),
            line(.closedHat, steps: 20, beat: 4, on: [4, 12]),
            line(.snare, steps: 20, beat: 4, on: [], ghosts: [6, 10, 14]),
            line(.kick, steps: 20, beat: 4, on: [0, 12]),
        ]),
        provenance: written("Five beats grouped three and two: the ride's swing figure over it, the hat on 2 and 4, the kick marking 1 and 4 where the groups start.",
                            lineage: ["Dave Brubeck Quartet, \"Take Five\"", "Joe Morello"]))

    /// 7/8, two steps per eighth, grouped 2+2+3.
    static let sevenEight = Feel(
        name: "Seven Eight",
        idioms: [.rock, Idiom("odd-meter")],
        tempoRange: 180...300, suggestedTempo: 250,
        timeSignature: TimeSignature(7, 8),
        groove: Groove(stepsPerBar: 14, bars: 1, swing: 0, patterns: [
            line(.closedHat, steps: 14, beat: 2, on: [0, 2, 4, 6, 8, 10, 12], accents: [0, 4, 8]),
            line(.snare, steps: 14, beat: 2, on: [4], ghosts: [11]),
            line(.kick, steps: 14, beat: 2, on: [0, 8, 10]),
        ]),
        provenance: written("Seven eighths grouped 2+2+3: hats on the eighths accenting each group, the snare on the second group, the kick on the first and the long last one.",
                            lineage: ["Peter Gabriel, \"Solsbury Hill\"", "Balkan 7/8"]))
}
