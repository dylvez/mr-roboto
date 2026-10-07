import MusicTheory
import SongGraph

// Latin feels, written for this app. The library had one — Bossa Nova — so "something Latin" had
// one answer. These are the patterns every drummer's method book agrees on, on the kit's hand
// percussion where the part is a hand part: the clave on the claves, the conga's tones on the
// congas, the shakers on the shaker, the bell on the cowbell — and the surdo on the kick. Each is two bars of sixteenths, because the clave is a two-bar cycle and a
// feel that stops after one bar of it has said half a sentence.
//
// They are marked `original`, not `researched`: no source is cited for the step numbers, and the
// provenance says what each line is standing in for so a persona — or a player who knows better —
// can argue with it.
extension Feels {

    static let latin: [Feel] = [sonClave32, sonClave23, rumbaClave, salsaTumbao, chaCha, samba, baiao, dembow, cumbia]

    private static func twoBars(_ patterns: [GroovePattern], swing: Double = 0) -> Groove {
        Groove(stepsPerBar: 16, bars: 2, swing: swing, patterns: patterns)
    }

    private static func written(_ summary: String, lineage: [String]) -> Provenance {
        Provenance(origin: .original, summary: summary, lineage: lineage)
    }

    /// The same steps in both bars.
    private static func both(_ steps: [Int]) -> [Int] { steps + steps.map { $0 + 16 } }

    static let sonClave32 = Feel(
        name: "Son Clave 3-2",
        idioms: [.latin],
        tempoRange: 85...125, suggestedTempo: 100,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.claves, steps: 32, beat: 4, on: [0, 6, 12, 20, 24], accents: [0, 6, 12, 20, 24]),
            line(.kick, steps: 32, beat: 4, on: both([6, 12])),
        ]),
        provenance: written("Son clave, three side first: three strokes in bar one, two in bar two, on the claves; the kick on the and of 2 and on 4, where the bass tumbao lands.",
                            lineage: ["Cuban son", "salsa"]))

    static let sonClave23 = Feel(
        name: "Son Clave 2-3",
        idioms: [.latin],
        tempoRange: 85...125, suggestedTempo: 100,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.claves, steps: 32, beat: 4, on: [4, 8, 16, 22, 28], accents: [4, 8, 16, 22, 28]),
            line(.kick, steps: 32, beat: 4, on: both([6, 12])),
        ]),
        provenance: written("Son clave, two side first: the same five strokes as 3-2 with the bars swapped, which is how most salsa tunes are phrased.",
                            lineage: ["Cuban son", "salsa"]))

    static let rumbaClave = Feel(
        name: "Rumba Clave",
        idioms: [.latin],
        tempoRange: 90...130, suggestedTempo: 108,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.claves, steps: 32, beat: 4, on: [0, 6, 14, 20, 24], accents: [0, 6, 14, 20, 24]),
            line(.kick, steps: 32, beat: 4, on: both([6, 12])),
            line(.highConga, steps: 32, beat: 4, on: both([12])),
            line(.lowConga, steps: 32, beat: 4, on: both([14])),
        ]),
        provenance: written("Rumba clave: son clave with its third stroke pushed a sixteenth late, the and of 4, which is what makes it lean. Conga open tones on 4 and, on the low drum, the and of 4.",
                            lineage: ["Cuban rumba", "guaguancó"]))

    static let salsaTumbao = Feel(
        name: "Salsa Tumbao",
        idioms: [.latin],
        tempoRange: 85...115, suggestedTempo: 96,
        groove: twoBars([
            line(.ride, steps: 32, beat: 4, on: eighths(upTo: 32), accents: both([0, 8])),
            line(.claves, steps: 32, beat: 4, on: [4, 8, 16, 22, 28], accents: [4, 8, 16, 22, 28]),
            line(.highConga, steps: 32, beat: 4, on: both([4, 12]), ghosts: both([0, 2, 8, 10]), accents: both([4])),
            line(.lowConga, steps: 32, beat: 4, on: both([14])),
            line(.kick, steps: 32, beat: 4, on: both([6, 12])),
        ]),
        provenance: written("The conga tumbao under a 2-3 clave: heel and tip ghosted, a slap on 2, an open tone on 4 and the low drum on the and of 4, a bell in eighths, and the kick where the bass anticipates.",
                            lineage: ["salsa", "Fania-era New York"]))

    static let chaCha = Feel(
        name: "Cha-Cha-Chá",
        idioms: [.latin],
        tempoRange: 105...130, suggestedTempo: 118,
        groove: twoBars([
            line(.cowbell, steps: 32, beat: 4, on: both([0, 4, 8, 12]), accents: both([0, 4, 8, 12])),
            line(.guiro, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.rim, steps: 32, beat: 4, on: both([12, 14]), ghosts: both([6])),
            line(.kick, steps: 32, beat: 4, on: both([0, 12])),
        ]),
        provenance: written("A cowbell on every beat over a güiro in eighths, and the 'cha-cha-chá' itself — 4, and, 1 — across the bar line on the rim and kick.",
                            lineage: ["Enrique Jorrín", "Cuban charanga"]))

    static let samba = Feel(
        name: "Samba",
        idioms: [.latin],
        tempoRange: 90...120, suggestedTempo: 104,
        groove: twoBars([
            line(.shaker, steps: 32, beat: 4, on: all(upTo: 32), accents: both([0, 3, 4, 7, 8, 11, 12, 15])),
            line(.rim, steps: 32, beat: 4, on: [0, 3, 6, 10, 13, 16, 19, 22, 26, 29]),
            line(.highAgogo, steps: 32, beat: 4, on: [0, 6, 10, 16, 22, 26], accents: [0, 16]),
            line(.lowAgogo, steps: 32, beat: 4, on: [3, 8, 13, 19, 24, 29]),
            line(.kick, steps: 32, beat: 4, on: both([0, 3, 4, 7, 8, 11, 12, 15]), accents: both([4, 12])),
        ]),
        provenance: written("The surdo's heartbeat on the kick — a light stroke, then the heavy one on 2 and 4 — under sixteenth shakers, with a simplified tamborim line on the rim and the agogô's two bells answering each other across the bar.",
                            lineage: ["Rio samba", "batucada"]))

    static let baiao = Feel(
        name: "Baião",
        idioms: [.latin, .folk],
        tempoRange: 90...125, suggestedTempo: 106,
        groove: twoBars([
            line(.muteTriangle, steps: 32, beat: 4, on: both([0, 1, 3, 4, 5, 7, 8, 9, 11, 12, 13, 15]),
                 ghosts: both([1, 5, 9, 13])),
            line(.openTriangle, steps: 32, beat: 4, on: both([2, 6, 10, 14])),
            line(.rim, steps: 32, beat: 4, on: both([6, 14])),
            line(.kick, steps: 32, beat: 4, on: both([0, 3, 8, 11]), accents: both([0, 8])),
        ]),
        provenance: written("The zabumba's dotted figure — a long stroke and a short one — on the kick, its high skin answering on the rim, and the triangle in sixteenths: held in the hand, let ring on the and of every beat.",
                            lineage: ["Luiz Gonzaga", "north-eastern Brazil"]))

    static let dembow = Feel(
        name: "Dembow",
        idioms: [.latin, .hipHop],
        tempoRange: 85...105, suggestedTempo: 94,
        groove: twoBars([
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.snare, steps: 32, beat: 4, on: both([3, 6, 11, 14]), accents: both([6, 14])),
            line(.kick, steps: 32, beat: 4, on: both([0, 4, 8, 12])),
        ]),
        provenance: written("Four on the floor with the snare on the a of 1 and the and of 2, twice a bar: the riddim under reggaeton.",
                            lineage: ["Shabba Ranks' Dem Bow", "reggaeton"]))

    /// Counted in four, two bars of the 2/4 the music is written in to each of its bars.
    static let cumbia = Feel(
        name: "Cumbia",
        idioms: [.latin],
        tempoRange: 80...105, suggestedTempo: 92,
        groove: twoBars([
            line(.guiroLong, steps: 32, beat: 4, on: both([0, 4, 8, 12])),
            line(.guiro, steps: 32, beat: 4, on: both([2, 3, 6, 7, 10, 11, 14, 15]),
                 ghosts: both([3, 7, 11, 15])),
            line(.shaker, steps: 32, beat: 4, on: eighths(upTo: 32), ghosts: both([2, 6, 10, 14])),
            line(.highConga, steps: 32, beat: 4, on: both([2, 6, 10, 14])),
            line(.lowConga, steps: 32, beat: 4, on: [7, 15, 23, 29, 31], ghosts: [5, 13, 21, 27]),
            line(.kick, steps: 32, beat: 4, on: both([0, 8])),
        ], swing: 0.2),
        provenance: written("The guacharaca's 'chu-chucu' — a long scrape on the beat and two short strokes after it — on the güiro, maracas in eighths, the llamador on every off-beat on the high conga, the alegre talking on the low one, and the tambora's downbeats on the kick. A little swing: cumbia is not played square.",
                            lineage: ["Colombian Caribbean coast", "cumbia sonidera"]))
}
