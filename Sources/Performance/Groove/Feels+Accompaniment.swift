import MusicTheory
import SongGraph

/// The rhythmic skeletons of The Chorus's accompaniment styles
/// (`The-Chorus/src/patterns/{ballad,broadway,fingerpicking,folk_strum,motown,pop_piano,waltz}.py`).
///
/// Those tables are accompaniment: piano voicings, bass motion and a drum layer, addressed by
/// harmonic role (`arp_0`, `root`, `fifth`) rather than by pitch. Only the rhythm ports — a groove
/// has no harmony — so what survives is each style's drum and percussion layer, at the subdivision
/// the source used (8 for eighths, 16 for Broadway's sixteenths, 6 for the waltz's eighths in 3/4).
///
/// The source's `intensity_layers` are folded in at full intensity, which is the only reading that
/// produces a complete pattern: the base `steps` of most of these tables carry piano and nothing
/// else. Its MIDI velocities carry over as tiers — 100 and 95 are accents, 75–90 normal, and
/// anything at or under 55 (the shakers, tambourines and brushed snares these styles lean on)
/// becomes a ghost, which is the whole character of the quieter ones.
///
/// These are one-bar patterns, unlike the two-bar `groove-theory` phrases, because the source is
/// one bar that repeats under a chord.
extension Feels {

    static let accompaniment: [Feel] = [
        balladBrushes, popPianoBackbeat, travisPicking, folkStrum,
        broadwayRide, soulTambourine, oomPahWaltz,
    ]

    private static func chorus(_ summary: String, file: String, think: [String]) -> Provenance {
        Provenance(origin: .theChorus, summary: summary,
                   source: "The-Chorus/src/patterns/\(file)", lineage: think)
    }

    /// `ballad.py` — 4/4, eighths. Soft kick on 1, brushed snare on 3, hats at 30–40 throughout.
    static let balladBrushes = Feel(
        name: "Ballad Brushes",
        idioms: [.ballad, .pop],
        tempoRange: 55...85, suggestedTempo: 68,
        groove: Groove(stepsPerBar: 8, bars: 1, swing: 0, patterns: [
            line(.closedHat, steps: 8, beat: 2, on: [0, 2, 4, 6], ghosts: [1, 3, 5, 7]),
            line(.snare, steps: 8, beat: 2, on: [], ghosts: [4]),
            line(.kick, steps: 8, beat: 2, on: [0]),
        ]),
        velocities: .soft,
        provenance: chorus("Kick on 1, brushed snare on 3, a whisper of hats on every eighth.",
                           file: "ballad.py", think: ["\"I Dreamed a Dream\"", "\"Someone Like You\""]))

    /// `pop_piano.py` — 4/4, eighths. Kick 1 and 3, snare 2 and 4, alternating hats, open hat on the
    /// last eighth.
    static let popPianoBackbeat = Feel(
        name: "Pop Piano Backbeat",
        idioms: [.pop, .rock],
        tempoRange: 100...140, suggestedTempo: 118,
        groove: Groove(stepsPerBar: 8, bars: 1, swing: 0, patterns: [
            line(.openHat, steps: 8, beat: 2, on: [7]),
            line(.closedHat, steps: 8, beat: 2, on: [0, 1, 2, 3, 4, 5, 6]),
            line(.snare, steps: 8, beat: 2, on: [2, 6]),
            line(.kick, steps: 8, beat: 2, on: [0, 4]),
        ]),
        provenance: chorus("Kick on 1 and 3, snare on 2 and 4, eighth hats, open hat into the turnaround.",
                           file: "pop_piano.py", think: ["\"Don't Stop Believin'\"", "\"Clocks\""]))

    /// `fingerpicking.py` — the only drum content is a shaker on the quarters. Kept as it is: a
    /// texture, not a kit, which is exactly what a Travis-picked verse wants under it.
    static let travisPicking = Feel(
        name: "Travis Shaker",
        idioms: [.folk, .ballad],
        tempoRange: 70...110, suggestedTempo: 88,
        groove: Groove(stepsPerBar: 8, bars: 1, swing: 0, patterns: [
            line(DrumVoice.perc, steps: 8, beat: 2, on: [0, 4], ghosts: [2, 6]),
        ]),
        velocities: .soft,
        provenance: chorus("Shaker on the quarters and nothing else — the texture under an alternating-bass pick.",
                           file: "fingerpicking.py", think: ["\"Landslide\"", "\"Dust in the Wind\""]))

    /// `folk_strum.py` — kick on 1 and 3, tambourine on every eighth alternating loud and soft.
    static let folkStrum = Feel(
        name: "Folk Strum",
        idioms: [.folk, .pop],
        tempoRange: 90...130, suggestedTempo: 112,
        groove: Groove(stepsPerBar: 8, bars: 1, swing: 0, patterns: [
            line(DrumVoice.perc, steps: 8, beat: 2, on: [0, 2, 4, 6], ghosts: [1, 3, 5, 7]),
            line(.kick, steps: 8, beat: 2, on: [0, 4]),
        ]),
        provenance: chorus("Kick on 1 and 3 under a tambourine on every eighth, loud-soft-loud-soft.",
                           file: "folk_strum.py", think: ["\"Ho Hey\"", "\"Wagon Wheel\""]))

    /// `broadway.py` — 4/4, sixteenths. Ride on the quarters, kick on 1, ghost snare on 2 and 4.
    static let broadwayRide = Feel(
        name: "Broadway Ride",
        idioms: [.musicalTheatre, .jazz],
        tempoRange: 70...120, suggestedTempo: 92,
        groove: Groove(stepsPerBar: 16, bars: 1, swing: 0, patterns: [
            line(.ride, steps: 16, beat: 4, on: [0, 4, 8, 12]),
            line(.snare, steps: 16, beat: 4, on: [], ghosts: [4, 12]),
            line(.kick, steps: 16, beat: 4, on: [0]),
        ]),
        velocities: .soft,
        provenance: chorus("Ride on the quarters with a ghosted backbeat under a rolling arpeggio.",
                           file: "broadway.py", think: ["\"Defying Gravity\"", "\"Memory\""]))

    /// `motown.py` — the accompaniment reading of Motown: hard backbeat, open hats on every eighth,
    /// tambourine on the quarters. Distinct from the `groove-theory` "Motown" template, which is a
    /// sixteenth-hat kit pattern.
    static let soulTambourine = Feel(
        name: "Soul Tambourine",
        idioms: [.motown, .soul],
        tempoRange: 95...130, suggestedTempo: 114,
        groove: Groove(stepsPerBar: 8, bars: 1, swing: 0, patterns: [
            line(.openHat, steps: 8, beat: 2, on: [0, 2, 4, 6], accents: [0, 2, 4, 6]),
            line(DrumVoice.perc, steps: 8, beat: 2, on: [], ghosts: [0, 2, 4, 6]),
            line(.snare, steps: 8, beat: 2, on: [2, 6], accents: [2, 6]),
            line(.kick, steps: 8, beat: 2, on: [0, 4]),
        ]),
        provenance: chorus("Hard backbeat, open hats on every eighth, tambourine on the quarters.",
                           file: "motown.py", think: ["\"Ain't No Mountain High Enough\""]))

    /// `waltz.py` — 3/4, six eighths. Kick on 1, hats on 2 and 3.
    static let oomPahWaltz = Feel(
        name: "Oom-Pah Waltz",
        idioms: [.waltz, .ballad],
        tempoRange: 80...150, suggestedTempo: 112,
        timeSignature: .threeFour,
        groove: Groove(stepsPerBar: 6, bars: 1, swing: 0, patterns: [
            line(.closedHat, steps: 6, beat: 2, on: [2, 4]),
            line(.kick, steps: 6, beat: 2, on: [0]),
        ]),
        velocities: .soft,
        provenance: chorus("Kick on 1, hats on 2 and 3 — the drum half of an oom-pah accompaniment.",
                           file: "waltz.py", think: ["\"Edelweiss\"", "\"My Favorite Things\""]))
}
