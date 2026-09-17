import MusicTheory
import SongGraph

/// The twelve beat templates from `groove-theory/src/constants/beats.ts`, ported step for step.
///
/// The source stores two bars as one flat boolean array (`subdivision: 32` is two bars of sixteenths
/// in 4/4, `24` is two bars of twelve in 3/4), so every one of these is `bars: 2` — they are phrases,
/// with a variation in the second bar, not one-bar loops.
///
/// Two deliberate departures from the source:
///
/// * **Shuffle's meter is corrected.** `beats.ts` labels it `3/4` with 24 steps, but its own kick
///   sits on steps 0 and 6 and its snare on 3 and 9, which is a backbeat on 2 and 4 of a **4/4** bar
///   subdivided into triplet eighths (three steps per beat). Read as 3/4 it would be nonsense.
///   Ported as 4/4, `stepsPerBar: 12`, and the shuffle therefore lives in the step grid rather than
///   in a swing value.
/// * **Velocity tiers are added.** The source is boolean. A step on a beat becomes an accent and a
///   step between beats becomes normal (see `Feels.line`), and ghosts are added only where the
///   source's own description says "ghost".
///
/// Swing is left straight on all twelve. These are templates, not pockets: the swing that belongs
/// to a *feel* is carried by the researched entries in `Feels.idiom`, and the web app applied swing
/// as a global transport setting rather than storing it per beat.
extension Feels {

    static let grooveTheory: [Feel] = [
        standardRock, fourOnTheFloor, boomBapTemplate, shuffle, bossaNova, trainBeat,
        reggaeOneDrop, motown, amenBreak, waltz, jazzWaltz, threeFourBallad,
    ]

    // MARK: 4/4, sixteenths

    private static func fourFour(_ patterns: [GroovePattern], swing: Double = 0) -> Groove {
        Groove(stepsPerBar: 16, bars: 2, swing: swing, patterns: patterns)
    }

    private static func provenance(_ summary: String, lineage: [String] = []) -> Provenance {
        Provenance(origin: .grooveTheory, summary: summary,
                   source: "groove-theory/src/constants/beats.ts", lineage: lineage)
    }

    static let standardRock = Feel(
        name: "Standard Rock",
        idioms: [.rock, .pop],
        tempoRange: 80...130, suggestedTempo: 105,
        groove: fourFour([
            line(.openHat, steps: 32, beat: 4, on: [28]),
            line(.closedHat, steps: 32, beat: 4, on: [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26]),
            line(.snare, steps: 32, beat: 4, on: [4, 12, 20, 28, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 8, 16, 24, 26]),
        ]),
        provenance: provenance(
            "Kick on 1 and 3, snare on 2 and 4, eighth-note hats; bar two adds an open hat and a kick push.",
            lineage: ["the default rock backbeat"]))

    static let fourOnTheFloor = Feel(
        name: "Four on the Floor",
        idioms: [.disco, .house, .electronic],
        tempoRange: 115...135, suggestedTempo: 124,
        groove: fourFour([
            line(.openHat, steps: 32, beat: 4, on: [30]),
            line(.closedHat, steps: 32, beat: 4, on: [2, 6, 10, 14, 18, 22, 26]),
            line(.clap, steps: 32, beat: 4, on: [20, 28]),
            line(.snare, steps: 32, beat: 4, on: [4, 12]),
            line(.kick, steps: 32, beat: 4, on: [0, 4, 8, 12, 16, 20, 24, 27, 28]),
        ]),
        velocities: .flat,
        provenance: provenance(
            "Kick on every beat under offbeat hats; bar two swaps the snare for a clap and syncopates the kick.",
            lineage: ["disco", "the TR-909 four-to-the-floor"]))

    /// The web app's boom-bap template. The *feel* with the researched swing and pocket is
    /// `Feels.boomBapPocket`; this is the pattern as the sequencer shipped it.
    static let boomBapTemplate = Feel(
        name: "Boom-Bap",
        idioms: [.boomBap, .hipHop],
        tempoRange: 80...100, suggestedTempo: 90,
        groove: fourFour([
            line(.openHat, steps: 32, beat: 4, on: [22]),
            line(.closedHat, steps: 32, beat: 4,
                 on: [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 26, 28, 30]),
            line(.snare, steps: 32, beat: 4, on: [8, 24, 30], ghosts: [23]),
            line(.kick, steps: 32, beat: 4, on: [0, 6, 16, 22, 30]),
        ]),
        provenance: provenance(
            "Kick on 1 and the and of 2, snare on 3; bar two adds a ghost snare and kick variations.",
            lineage: ["golden-era East Coast hip-hop"]))

    /// 4/4 in triplet eighths — see the note on the extension about `beats.ts`'s meter label.
    static let shuffle = Feel(
        name: "Shuffle",
        idioms: [.blues, .rock],
        tempoRange: 100...140, suggestedTempo: 120,
        groove: Groove(stepsPerBar: 12, bars: 2, swing: 0, patterns: [
            line(.openHat, steps: 24, beat: 3, on: [21]),
            line(.closedHat, steps: 24, beat: 3, on: [0, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 23]),
            line(.snare, steps: 24, beat: 3, on: [3, 9, 15, 21], ghosts: [23]),
            line(.kick, steps: 24, beat: 3, on: [0, 6, 12, 17, 18]),
        ]),
        provenance: provenance(
            "A triplet shuffle: the hats skip the middle triplet, the backbeat sits on 2 and 4.",
            lineage: ["twelve-bar blues", "the Texas shuffle"]))

    static let bossaNova = Feel(
        name: "Bossa Nova",
        idioms: [.latin, .jazz],
        tempoRange: 120...145, suggestedTempo: 132,
        groove: fourFour([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.rim, steps: 32, beat: 4, on: [4, 10, 20, 22, 28]),
            line(.kick, steps: 32, beat: 4, on: [0, 6, 8, 14, 16, 22, 24, 30]),
        ]),
        provenance: provenance(
            "The two-bar clave cycle: a syncopated cross-stick over a steady pulse.",
            lineage: ["João Gilberto", "Brazilian jazz"]))

    static let trainBeat = Feel(
        name: "Train Beat",
        idioms: [.country, .folk],
        tempoRange: 100...140, suggestedTempo: 120,
        groove: fourFour([
            line(.openHat, steps: 32, beat: 4, on: [24]),
            line(.closedHat, steps: 32, beat: 4, on: [0, 4, 8, 12, 16, 20, 28]),
            // "Alternating hands on the snare": the off-beat hand is the quiet one, which is what
            // makes the gallop rather than a machine gun.
            line(.snare, steps: 32, beat: 4, on: eighths(upTo: 32),
                 ghosts: [2, 6, 10, 14, 18, 22, 26, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 8, 16, 24, 26, 28]),
        ]),
        provenance: provenance(
            "Alternating hands on the snare over quarter-note hats — the freight-train gallop.",
            lineage: ["Bakersfield country", "Buck Owens"]))

    static let reggaeOneDrop = Feel(
        name: "Reggae One Drop",
        idioms: [.reggae],
        tempoRange: 65...90, suggestedTempo: 76,
        groove: fourFour([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.rim, steps: 32, beat: 4, on: [], ghosts: [22]),
            line(.snare, steps: 32, beat: 4, on: [8, 24]),
            line(.kick, steps: 32, beat: 4, on: [8, 23, 24]),
        ]),
        provenance: provenance(
            "Kick and snare together on beat 3 and nothing on 1; bar two anticipates the drop.",
            lineage: ["Carlton Barrett", "the Wailers"]))

    static let motown = Feel(
        name: "Motown",
        idioms: [.motown, .soul],
        tempoRange: 100...130, suggestedTempo: 116,
        groove: fourFour([
            line(.openHat, steps: 32, beat: 4, on: [22, 30]),
            line(.closedHat, steps: 32, beat: 4,
                 on: Array(0...15) + [16, 17, 18, 19, 20, 21, 23, 24, 25, 26, 27, 28, 29]),
            line(.snare, steps: 32, beat: 4, on: [4, 12, 20, 28]),
            line(.kick, steps: 32, beat: 4, on: [0, 8, 16, 24, 27]),
        ]),
        provenance: provenance(
            "Driving sixteenth hats with the backbeat on 2 and 4 and a kick push before 4.",
            lineage: ["Benny Benjamin", "the Funk Brothers"]))

    static let amenBreak = Feel(
        name: "Breakbeat (Amen)",
        idioms: [.breakbeat, .funk, .drumAndBass],
        tempoRange: 130...170, suggestedTempo: 150,
        groove: fourFour([
            line(.ride, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.snare, steps: 32, beat: 4, on: [4, 10, 14, 20, 26, 28, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 6, 10, 16, 22, 25]),
        ]),
        provenance: provenance(
            "A displaced funk pattern after the Amen break; bar two rolls the snare and pushes the kick.",
            lineage: ["The Winstons, \"Amen, Brother\"", "jungle"]))

    // MARK: 3/4

    private static func threeFour(_ patterns: [GroovePattern]) -> Groove {
        Groove(stepsPerBar: 12, bars: 2, swing: 0, patterns: patterns)
    }

    static let waltz = Feel(
        name: "Waltz",
        idioms: [.waltz, .pop],
        tempoRange: 80...140, suggestedTempo: 108,
        timeSignature: .threeFour,
        groove: threeFour([
            line(.openHat, steps: 24, beat: 4, on: [18]),
            line(.closedHat, steps: 24, beat: 4, on: [0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 22]),
            line(.snare, steps: 24, beat: 4, on: [4, 8, 16, 20]),
            line(.kick, steps: 24, beat: 4, on: [0, 12, 22]),
        ]),
        provenance: provenance("Oom-pah-pah: kick on the downbeat, snare on 2 and 3."))

    static let jazzWaltz = Feel(
        name: "Jazz Waltz",
        idioms: [.jazz, .waltz],
        tempoRange: 100...160, suggestedTempo: 130,
        timeSignature: .threeFour,
        groove: threeFour([
            line(.ride, steps: 24, beat: 4, on: [0, 4, 8, 12, 14, 16, 20]),
            line(.closedHat, steps: 24, beat: 4, on: [2, 6, 10, 14, 18, 22]),
            line(.snare, steps: 24, beat: 4, on: [], ghosts: [6, 16, 18]),
            line(.kick, steps: 24, beat: 4, on: [0, 8, 12, 19]),
        ]),
        provenance: provenance(
            "Ride on the quarters with brushed ghost snares; bar two adds ride upbeats and a kick push.",
            lineage: ["Bill Evans Trio", "Paul Motian"]))

    static let threeFourBallad = Feel(
        name: "3/4 Ballad",
        idioms: [.ballad, .folk],
        tempoRange: 60...100, suggestedTempo: 76,
        timeSignature: .threeFour,
        groove: threeFour([
            line(.openHat, steps: 24, beat: 4, on: [20]),
            line(.closedHat, steps: 24, beat: 4, on: [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 22]),
            line(.snare, steps: 24, beat: 4, on: [8, 20]),
            line(.midTom, steps: 24, beat: 4, on: [21, 22, 23]),
            line(.kick, steps: 24, beat: 4, on: [0, 12]),
        ]),
        velocities: .soft,
        provenance: provenance("Light kick and cross-stick with a tom fill into the next phrase."))
}
