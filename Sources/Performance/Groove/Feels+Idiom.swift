import MusicTheory
import SongGraph

/// The feels the first idiom actually needs — electronic, lo-fi, sample-based — and that neither
/// `groove-theory` nor The Chorus had.
///
/// These are the only entries in the library that carry a *pocket* as well as a pattern: a swing
/// percentage, per-voice displacement and a humanize amount, all from the sources cited on each
/// one. The two ported sets are templates; these are supposed to sound like somebody.
///
/// ## What the research settled
///
/// **Swing is quoted as an MPC percentage everywhere in this literature**, which is why `Swing`
/// speaks that language: 50 straight, 66.67 triplet, 75 the machines' maximum. Roger Linn's own
/// guidance is the anchor — "a 90 BPM swing groove will feel looser at 62% than at a perfect swing
/// setting of 66%", and "for straight 16th-note beats, a swing setting of 54% will loosen up the
/// feel without it sounding like swing"
/// (<https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/>).
///
/// **Boom-bap** sits at 85–95 BPM with swing between 52% and 62% and micro-timing nudges of five to
/// fifteen milliseconds; the kick lands on the first, fourth and sixth eighth notes with the snare
/// on 2 and 4 (<https://tellingbeatzz.com/boom-bap-bpm/>,
/// <https://blog.native-instruments.com/what-is-boom-bap/>).
///
/// **Lo-fi hip-hop** runs slower — commonly quoted as 60–90 BPM, with the "lofi hip hop radio"
/// centre of gravity around 80–85 — and the production guides specifically say to swing the
/// sixteenths to around 60% and to leave hits off the grid on purpose
/// (<https://blog.native-instruments.com/lo-fi-hip-hop-beats/>,
/// <https://www.edmprod.com/lofi-hip-hop/>, <https://bpmcalc.com/genres/lo-fi/>).
///
/// **The Dilla feel** is not a swing setting but *independent* displacement: the MPC3000 let you
/// "swing the snare but not the kick, and swing the hi-hats a little while swinging the snare a
/// lot" (<https://mixdownmag.com.au/features/gear-rundown-j-dilla/>). The direction is genuinely
/// contested — the MPC3000 accounts and this project's own persona material describe the snare
/// pushed late against straight hats, while at least one analysis reports the snare slightly early
/// with the upbeat hats nudged back
/// (<https://gearspace.com/board/rap-hip-hop-engineering-and-production/864711-j-dilla-quot-swing-quot-his-beats.html>).
/// `Feels.lofiHipHop` encodes the first reading, which is the one the M1 spec asks for, and the
/// second is one sign flip away in `voices`. Settled for this house by ear on 2026-09-18: late,
/// at the 21 ms the A/B used (`DILLA_DEMO=1 swift test --filter dillaDemo`).
///
/// **Trap** runs 130–160 BPM with a half-time kick and snare — snare on beat 3 only — under hats at
/// full tempo, punctuated by three or four thirty-second notes rolling into the snare
/// (<https://blog.native-instruments.com/how-to-make-a-trap-beat/>,
/// <https://www.musicradar.com/how-to/how-to-program-mixed-resolution-trap-style-hi-hat-patterns>).
/// That roll is why this is the one feel on a thirty-second grid.
///
/// **Lo-fi house** sits at 115–125 BPM: four-on-the-floor with off-beat open hats and a clap on 2
/// and 4, played dirty (<https://splice.com/blog/lo-fi-house-beatmaker-astra/>,
/// <https://padwolf.app/learn/bpm-chart-by-genre/>).
///
/// **Trip-hop** is a breakbeat slowed down: a funk break at 130+ pitched down to around 85, drums
/// heavy and dragging, classic Bristol sitting at 80–95
/// (<https://www.musicradar.com/tutorials/the-core-thing-to-remember-is-that-your-beats-are-slow-90-bpm-maximum-and-they-are-filthy-unpacking-the-dark-sample-based-sound-of-trip-hop>).
///
/// **Neo-soul** is Dilla's off-grid programming translated back to hands: the groove drags its
/// downbeats behind the click, the snare is late and doubled with a clap that is not quantised to
/// it, and ghost notes fill every gap
/// (<https://slavetomusic.com/voodoo-neo-soul-time-travel-and-the-art-of-the-groove/>,
/// <https://www.slate.com/articles/arts/music_box/2013/02/behind_the_scenes_with_questlove_and_d_angelo_on_voodoo.html>).
extension Feels {

    static let idiom: [Feel] = [
        lofiHipHop, boomBapPocket, trapRollingHats, lofiHouse, tripHop, neoSoulPocket,
    ]

    private static func researched(_ summary: String, lineage: [String], references: [String]) -> Provenance {
        Provenance(origin: .researched, summary: summary, source: nil,
                   lineage: lineage, references: references)
    }

    // MARK: Lo-fi hip-hop

    /// Sixteenths swung to 60%, hats held straight against a late snare — the drunk feel.
    static let lofiHipHop = Feel(
        name: "Lo-Fi Hip-Hop",
        idioms: [.lofi, .hipHop],
        tempoRange: 68...92, suggestedTempo: 82,
        groove: Groove(stepsPerBar: 16, bars: 2, swing: Swing(percent: 60).factor, patterns: [
            line(.openHat, steps: 32, beat: 4, on: [14]),
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.snare, steps: 32, beat: 4, on: [4, 12, 20, 28], ghosts: [7, 23]),
            line(.kick, steps: 32, beat: 4, on: [0, 10, 16, 19, 26]),
        ]),
        velocities: .soft,
        humanize: Humanize(velocity: 0.20, timing: 0.10, seed: 0x10F1_0001),
        voices: [
            // The whole point: the hats keep the grid while the snare leans back against them.
            .closedHat: VoiceFeel(swing: .straight, humanizeScale: 0.5),
            .openHat: VoiceFeel(swing: .straight, humanizeScale: 0.5),
            // 21 ms at the suggested 82 bpm: the exact displacement that won the A/B.
            .snare: VoiceFeel(timingOffset: 0.115),
            .kick: VoiceFeel(timingOffset: 0.03),
        ],
        provenance: researched(
            "Sixteenths swung to 60% with the hats held straight and the snare leaning back — the drunk pocket.",
            lineage: ["J Dilla", "Nujabes", "the MPC3000's per-pad swing"],
            references: [
                "https://blog.native-instruments.com/lo-fi-hip-hop-beats/",
                "https://www.edmprod.com/lofi-hip-hop/",
                "https://mixdownmag.com.au/features/gear-rundown-j-dilla/",
                "https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/",
            ]))

    // MARK: Boom-bap

    /// 90 BPM, swing 56%, kick on the first, fourth and sixth eighths.
    static let boomBapPocket = Feel(
        name: "Boom-Bap Pocket",
        idioms: [.boomBap, .hipHop],
        tempoRange: 85...95, suggestedTempo: 90,
        groove: Groove(stepsPerBar: 16, bars: 2, swing: Swing(percent: 56).factor, patterns: [
            line(.openHat, steps: 32, beat: 4, on: [14]),
            line(.closedHat, steps: 32, beat: 4, on: eighths(upTo: 32)),
            line(.snare, steps: 32, beat: 4, on: [4, 12, 20, 28], ghosts: [7, 14, 23, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 6, 10, 16, 22, 26, 29]),
        ]),
        velocities: .wide,
        humanize: Humanize(velocity: 0.16, timing: 0.06, seed: 0xB00_1BA9),
        voices: [.snare: VoiceFeel(timingOffset: 0.05)],
        provenance: researched(
            "Kick on the first, fourth and sixth eighths, snare on 2 and 4, swing 56% — the 90 BPM pocket.",
            lineage: ["DJ Premier", "Pete Rock", "the E-mu SP-1200"],
            references: [
                "https://tellingbeatzz.com/boom-bap-bpm/",
                "https://blog.native-instruments.com/what-is-boom-bap/",
                "https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/",
            ]))

    // MARK: Trap

    /// The only feel on a thirty-second grid: the rolls need it. Eight steps to the beat.
    static let trapRollingHats = Feel(
        name: "Trap Rolling Hats",
        idioms: [.trap, .hipHop],
        tempoRange: 130...160, suggestedTempo: 142,
        groove: Groove(stepsPerBar: 32, bars: 2, swing: 0, patterns: [
            line(.openHat, steps: 64, beat: 8, on: [30]),
            line(.closedHat, steps: 64, beat: 8,
                 on: [0, 2, 4, 6, 8, 10,
                      12, 13, 14, 15,            // four thirty-seconds rolling into the snare
                      16, 18, 20, 22, 24, 26, 28, 30,
                      32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58,
                      60, 61, 62, 63],           // and again into the top of the phrase
                 ghosts: [13, 15, 61, 63]),
            // Half-time: clap and snare stack on beat 3 and nowhere else.
            line(.clap, steps: 64, beat: 8, on: [16, 48]),
            line(.snare, steps: 64, beat: 8, on: [16, 48]),
            line(.kick, steps: 64, beat: 8, on: [0, 12, 22, 32, 40, 46, 54]),
        ]),
        velocities: .flat,
        humanize: Humanize(velocity: 0.06, timing: 0, seed: 0x7_4A9_00),
        provenance: researched(
            "Half-time kick and clap on beat 3 under hats at full tempo, with thirty-second rolls into the snare.",
            lineage: ["Lex Luger", "Metro Boomin", "the TR-808"],
            references: [
                "https://blog.native-instruments.com/how-to-make-a-trap-beat/",
                "https://www.musicradar.com/how-to/how-to-program-mixed-resolution-trap-style-hi-hat-patterns",
            ]))

    // MARK: Lo-fi house

    static let lofiHouse = Feel(
        name: "Lo-Fi House",
        idioms: [.house, .lofi, .electronic],
        tempoRange: 115...125, suggestedTempo: 120,
        groove: Groove(stepsPerBar: 16, bars: 2, swing: Swing(percent: 54).factor, patterns: [
            line(.openHat, steps: 32, beat: 4, on: [2, 6, 10, 14, 18, 22, 26, 30]),
            line(.closedHat, steps: 32, beat: 4, on: [], ghosts: [1, 5, 9, 13, 17, 21, 25, 29]),
            line(.clap, steps: 32, beat: 4, on: [4, 12, 20, 28]),
            line(.kick, steps: 32, beat: 4, on: [0, 4, 8, 12, 16, 20, 24, 28]),
        ]),
        velocities: .flat,
        humanize: Humanize(velocity: 0.12, timing: 0.05, seed: 0x10F1_4055),
        voices: [
            // The kick is the one thing that stays on the floor; everything else is allowed to smear.
            .kick: VoiceFeel(swing: .straight, humanizeScale: 0.2),
        ],
        provenance: researched(
            "Four on the floor with off-beat open hats and a clap on 2 and 4, swung 54% and played dirty.",
            lineage: ["DJ Seinfeld", "Ross From Friends", "the TR-909 through a tape machine"],
            references: [
                "https://splice.com/blog/lo-fi-house-beatmaker-astra/",
                "https://padwolf.app/learn/bpm-chart-by-genre/",
            ]))

    // MARK: Trip-hop

    static let tripHop = Feel(
        name: "Trip-Hop",
        idioms: [.tripHop, .electronic, .lofi],
        tempoRange: 70...95, suggestedTempo: 85,
        groove: Groove(stepsPerBar: 16, bars: 2, swing: Swing(percent: 54).factor, patterns: [
            line(.closedHat, steps: 32, beat: 4, on: [0, 4, 8, 12, 16, 20, 24, 28],
                 ghosts: [2, 6, 10, 14, 18, 22, 26, 30]),
            line(.rim, steps: 32, beat: 4, on: [], ghosts: [7, 23]),
            line(.snare, steps: 32, beat: 4, on: [4, 12, 20, 28], ghosts: [14, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 10, 16, 22, 26]),
        ]),
        velocities: .wide,
        humanize: Humanize(velocity: 0.20, timing: 0.08, seed: 0x7217_4F09),
        voices: [
            .snare: VoiceFeel(timingOffset: 0.08),
            .kick: VoiceFeel(timingOffset: 0.05),
        ],
        provenance: researched(
            "A funk break slowed to 85 and left heavy: dragging kick, ghosted hats, cross-stick on the ands.",
            lineage: ["Massive Attack", "Portishead", "the Bristol sound"],
            references: [
                "https://www.musicradar.com/tutorials/the-core-thing-to-remember-is-that-your-beats-are-slow-90-bpm-maximum-and-they-are-filthy-unpacking-the-dark-sample-based-sound-of-trip-hop",
                "https://beatkey.app/how-to-make-trip-hop-music",
            ]))

    // MARK: Neo-soul

    static let neoSoulPocket = Feel(
        name: "Neo-Soul Pocket",
        idioms: [.neoSoul, .soul, .hipHop],
        tempoRange: 68...95, suggestedTempo: 80,
        groove: Groove(stepsPerBar: 16, bars: 2, swing: Swing(percent: 58).factor, patterns: [
            line(.closedHat, steps: 32, beat: 4, on: [0, 4, 8, 12, 16, 20, 24, 28],
                 ghosts: [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15,
                          17, 18, 19, 21, 22, 23, 25, 26, 27, 29, 30, 31]),
            line(.snare, steps: 32, beat: 4, on: [4, 12, 20, 28],
                 ghosts: [2, 6, 11, 14, 18, 23, 30]),
            line(.kick, steps: 32, beat: 4, on: [0, 7, 10, 16, 22, 26]),
        ]),
        velocities: .wide,
        humanize: Humanize(velocity: 0.16, timing: 0.05, seed: 0x4E50_5001),
        voices: [
            // The whole kit drags; the snare drags most. This is Questlove playing Dilla by hand.
            .snare: VoiceFeel(timingOffset: 0.12),
            .kick: VoiceFeel(timingOffset: 0.04),
            .closedHat: VoiceFeel(timingOffset: 0.02, humanizeScale: 0.6),
        ],
        provenance: researched(
            "The whole kit behind the click with sixteenth ghost notes filling every gap and the snare latest of all.",
            lineage: ["Questlove", "D'Angelo, \"Voodoo\"", "J Dilla, translated to hands"],
            references: [
                "https://slavetomusic.com/voodoo-neo-soul-time-travel-and-the-art-of-the-groove/",
                "https://www.slate.com/articles/arts/music_box/2013/02/behind_the_scenes_with_questlove_and_d_angelo_on_voodoo.html",
            ]))
}
