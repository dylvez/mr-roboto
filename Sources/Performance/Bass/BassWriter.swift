import Foundation
import MusicTheory
import SongGraph

// MARK: - Lineage

/// Whose hands write the line. The three lineages of the Bassist bible, as the writer's own switch.
///
/// The names are the bible's: **A** Pino Palladino in the Voodoo years, who owns time placement and
/// note length; **B** Thundercat, who owns harmony and register; **C** the programmed low end —
/// Dilla's Moog and sampled bass, the 808 as the bass — where the line *is* the kick. Jamerson is
/// the shared root of A and B and supplies the chromatic approach both use.
public enum BassLineage: String, Codable, Sendable, Hashable, CaseIterable {
    case palladino
    case thundercat
    case programmed

    public var name: String {
        switch self {
        case .palladino: return "Palladino"
        case .thundercat: return "Thundercat"
        case .programmed: return "Programmed"
        }
    }

    /// R1: the default lag behind the kick, in milliseconds. +40 is the bible's safe default for
    /// lineage A (Skaansar's ±40 rated level with on-grid); B's 0–20 is a placeholder the bible
    /// marks as such; C is the kick, so 0.
    public var defaultLagMS: Double {
        switch self {
        case .palladino: return 40
        case .thundercat: return 10
        case .programmed: return 0
        }
    }

    /// Register bounds from the bible's feature table, as MIDI notes: D1–D3 tuned down a step for
    /// A, B0–G4 for B, E0–E2 for C. The writer stays inside these.
    public var register: ClosedRange<Int> {
        switch self {
        case .palladino: return 26...50
        case .thundercat: return 35...67
        case .programmed: return 16...40
        }
    }

    /// Where a root is placed when it has a choice: the middle of the useful part of the register.
    var preferredRoot: ClosedRange<Int> {
        switch self {
        case .palladino: return 33...45
        case .thundercat: return 38...50
        case .programmed: return 28...40
        }
    }

    /// The bass sound the lineage plays through by default.
    public var defaultSound: String {
        switch self {
        case .palladino, .thundercat: return "finger"
        case .programmed: return "sub"
        }
    }
}

// MARK: - The request

/// Everything the writer needs, in engine units. Nothing here is an adjective.
public struct BassRequest: Hashable, Sendable {
    public var key: Key
    /// The harmony, as chord spans in beats, cycled across the loop. Empty means "no chords
    /// stated": the writer takes the key's I, IV, V, I a bar each, and says so in its note.
    public var chords: [ChordSpan]
    /// The groove the line sits under: its kick pattern is the reference for every onset.
    public var groove: Groove
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var lineage: BassLineage
    /// Milliseconds behind the kick, positive = late. Baked into the note starts, because the
    /// line's placement is a fact about the line the Bassist measures, not a playback setting.
    public var lagMS: Double
    /// 0…1: how busy. Maps onto attacks per bar inside the lineage's band.
    public var density: Double
    /// The one sanctioned early pattern (R2's exception, "I Don't Know"): every other onset lands
    /// up to 25 ms *before* the grid instead of after it. Off by default.
    public var earlyAlternation: Bool
    /// The bass sound, by voice id. Nil takes the lineage's default.
    public var sound: String?
    public var seed: UInt64

    public init(key: Key, chords: [ChordSpan] = [], groove: Groove, tempo: Double,
                timeSignature: TimeSignature = .fourFour, lineage: BassLineage = .palladino,
                lagMS: Double? = nil, density: Double = 0.5, earlyAlternation: Bool = false,
                sound: String? = nil, seed: UInt64 = 0xBA55_0001) {
        self.key = key
        self.chords = chords
        self.groove = groove
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.lineage = lineage
        self.lagMS = lagMS ?? lineage.defaultLagMS
        self.density = min(1, max(0, density))
        self.earlyAlternation = earlyAlternation
        self.sound = sound
        self.seed = seed
    }

    /// The chords the writer actually uses: the stated ones, or the key's I–IV–V–I.
    public var effectiveChords: [ChordSpan] {
        if !chords.isEmpty { return chords }
        let beats = Double(max(1, timeSignature.beatsPerBar))
        let scale = key.scale
        let root = key.tonic.pitchClass
        return [1, 4, 5, 1].compactMap { degree in
            scale.diatonicChord(degree: degree, root: root, size: 4).map { ChordSpan($0, beats: beats) }
        }
    }

    public var usesDefaultChords: Bool { chords.isEmpty }
}

// MARK: - The writer

/// Writes a bass line under a groove. Deterministic: the same request gives the same line.
///
/// This is the arithmetic half of the Bassist. Everything the bible states as a number — where an
/// onset sits against the kick (R1), what ends a note (R8), when a root is approached from below
/// (R13), how many attacks a bar gets (R14), when the line is the kick (R9) — is a decision made
/// here. The judgement half, the readings and refusals, lives in the Bassist persona, which reads
/// the result back through `BassObservation` and never trusts this code to have followed its own
/// rules.
public enum BassWriter {

    /// One written note, before it becomes a `NoteEvent`: beats on the grid, then displacement.
    struct Draft {
        var pitch: Int
        var start: Double
        var end: Double
        var velocity: Int
        /// Whether the R1 lag applies. Approach notes and ghosts sit where they were put.
        var displaced: Bool = true
    }

    public static func write(_ request: BassRequest) -> Bassline {
        let beatsPerBar = Double(max(1, request.timeSignature.beatsPerBar))
        let bars = max(1, request.groove.bars)
        let totalBeats = beatsPerBar * Double(bars)
        let kicks = kickOnsets(in: request.groove, beatsPerBar: beatsPerBar)
        let harmony = HarmonyMap(chords: request.effectiveChords, totalBeats: totalBeats)
        var rng = BassRandom(seed: request.seed)

        var drafts: [Draft]
        switch request.lineage {
        case .palladino:
            drafts = writePalladino(request, kicks: kicks, harmony: harmony, beatsPerBar: beatsPerBar,
                                    bars: bars, rng: &rng)
        case .thundercat:
            drafts = writeThundercat(request, kicks: kicks, harmony: harmony, beatsPerBar: beatsPerBar,
                                     bars: bars, rng: &rng)
        case .programmed:
            drafts = writeProgrammed(request, kicks: kicks, harmony: harmony, beatsPerBar: beatsPerBar,
                                     bars: bars)
        }

        // Placement. R1's lag, in beats at this tempo, on every displaced onset; or the alternating
        // early pattern, which is the only early one the bible sanctions.
        let lagBeats = request.lagMS / 1000 * request.tempo / 60
        let earlyBeats = -0.025 * request.tempo / 60
        var onsetIndex = 0
        drafts.sort { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        var placed: [NoteEvent] = []
        var lastStart = -1.0
        for draft in drafts {
            var start = draft.start
            if draft.displaced {
                if draft.start != lastStart { onsetIndex += 1; lastStart = draft.start }
                let shift = request.earlyAlternation && onsetIndex % 2 == 0 ? earlyBeats : lagBeats
                start += shift
            }
            let end = max(start + 0.05, draft.end)
            placed.append(NoteEvent(pitch: Pitch(midi: draft.pitch), start: max(0, start),
                                    duration: end - max(0, start), velocity: draft.velocity))
        }
        return Bassline(notes: placed, sound: request.sound ?? request.lineage.defaultSound)
    }

    // MARK: Lineage A — Palladino

    /// Time placement and note length. Attacks come from the kick, thinned to the density; the
    /// downbeat is never left alone (R7); every note ends on a beat line (R8); a root move of a
    /// third or more is approached from the half-step below on the last eighth (R13); the bar
    /// stays inside R14's attack budget; ghost notes fill a little of the rest.
    private static func writePalladino(_ request: BassRequest, kicks: [Double], harmony: HarmonyMap,
                                       beatsPerBar: Double, bars: Int, rng: inout BassRandom) -> [Draft] {
        var drafts: [Draft] = []
        let budget = attackBudget(density: request.density, tempo: request.tempo, lineage: .palladino)
        var lastPitch: Int?

        for bar in 0..<bars {
            let barStart = Double(bar) * beatsPerBar
            let barEnd = barStart + beatsPerBar
            var onsets = Set<Double>()
            onsets.insert(barStart)                                    // R7: the downbeat
            let barKicks = kicks.filter { $0 >= barStart && $0 < barEnd }
            // R7: the and of 1 together with the kick when the kick is there.
            if barKicks.contains(where: { abs($0 - (barStart + 0.5)) < 1e-6 }) { onsets.insert(barStart + 0.5) }
            // Then the kick's own onsets, on-beat ones first, until the budget is spent.
            let ranked = barKicks.sorted { a, b in
                let aOn = a.truncatingRemainder(dividingBy: 1) == 0, bOn = b.truncatingRemainder(dividingBy: 1) == 0
                return aOn != bOn ? aOn : a < b
            }
            for kick in ranked where onsets.count < budget { onsets.insert(kick) }
            // A chord change inside the bar is an onset too, budget or not: the root has to move.
            for change in harmony.changes where change > barStart && change < barEnd { onsets.insert(change) }
            // Past the kick, the budget is spent on the ands — Jamerson's syncopated eighths —
            // picked by the seed, so a busier line is busier off the beat rather than on it.
            var ands = stride(from: barStart + 0.5, to: barEnd, by: 1).filter { !onsets.contains($0) }
            while onsets.count < budget, !ands.isEmpty {
                onsets.insert(ands.remove(at: Int(rng.unit() * Double(ands.count)) % ands.count))
            }

            let sorted = onsets.sorted()
            for (i, onset) in sorted.enumerated() {
                let chord = harmony.chord(at: onset)
                let pitch = place(chord.root, near: lastPitch, in: request.lineage)
                lastPitch = pitch
                let nextOnset = i + 1 < sorted.count ? sorted[i + 1] : barEnd
                // R8: end on the first beat line after a minimum sounding length, never past the
                // next attack. Half a beat minimum keeps the very short notes out.
                let earliestEnd = onset + 0.5
                var end = (earliestEnd).rounded(.up)
                if end - onset < 0.5 { end += 1 }
                end = min(end, nextOnset)
                drafts.append(Draft(pitch: pitch, start: onset, end: end, velocity: 100 + Int(rng.unit() * 8)))
            }
        }

        // R13: approach from below on the last eighth before a root move of a third or more.
        drafts += approaches(harmony: harmony, lineage: .palladino, minimumMove: 3, totalBeats: beatsPerBar * Double(bars))

        // Ghosts: a muted attack in a rest, about one a bar, never on a beat.
        for bar in 0..<bars {
            guard rng.unit() < 0.7 else { continue }
            let barStart = Double(bar) * beatsPerBar
            let slot = barStart + Double(Int(rng.unit() * (beatsPerBar * 2 - 1))) * 0.5 + 0.25
            let busy = drafts.contains { $0.start <= slot && $0.end > slot }
            guard !busy, slot < barStart + beatsPerBar else { continue }
            let chord = harmony.chord(at: slot)
            drafts.append(Draft(pitch: place(chord.root, near: lastPitch, in: .palladino), start: slot,
                                end: slot + 0.12, velocity: 42, displaced: false))
        }
        return drafts
    }

    // MARK: Lineage B — Thundercat

    /// Harmony and register. The line states the chord: root, then the tones above it as melody
    /// notes inside the chord; on a change it may sound the seventh and third together (R16).
    /// Approaches on every root move of a third or more, and half the smaller ones.
    private static func writeThundercat(_ request: BassRequest, kicks: [Double], harmony: HarmonyMap,
                                        beatsPerBar: Double, bars: Int, rng: inout BassRandom) -> [Draft] {
        var drafts: [Draft] = []
        let budget = attackBudget(density: request.density, tempo: request.tempo, lineage: .thundercat)
        var lastPitch: Int?

        for bar in 0..<bars {
            let barStart = Double(bar) * beatsPerBar
            let barEnd = barStart + beatsPerBar
            var onsets: [Double] = [barStart]
            for change in harmony.changes where change > barStart && change < barEnd { onsets.append(change) }
            // Fill towards the budget on eighths, favouring the ones a kick is on.
            var candidates = stride(from: barStart + 0.5, to: barEnd, by: 0.5).filter { !onsets.contains($0) }
            candidates.sort { a, b in
                let aKick = kicks.contains { abs($0 - a) < 1e-6 }, bKick = kicks.contains { abs($0 - b) < 1e-6 }
                return aKick != bKick ? aKick : rng.unit() < 0.5
            }
            for c in candidates where onsets.count < budget { onsets.append(c) }
            onsets.sort()

            var tone = 0
            for (i, onset) in onsets.enumerated() {
                let chord = harmony.chord(at: onset)
                let isChange = i == 0 || harmony.changes.contains(onset)
                let tones = chord.intervals
                let interval = isChange ? 0 : tones[min(tones.count - 1, 1 + (tone % max(1, tones.count - 1)))]
                if !isChange { tone += 1 }
                let root = place(chord.root, near: lastPitch, in: .thundercat)
                let pitch = clampToRegister(root + interval, .thundercat)
                lastPitch = root
                let nextOnset = i + 1 < onsets.count ? onsets[i + 1] : barEnd
                // Staccato between changes, held on them.
                let end = isChange ? min(nextOnset, onset + 1) : min(nextOnset, onset + 0.3)
                drafts.append(Draft(pitch: pitch, start: onset, end: end, velocity: 96 + Int(rng.unit() * 10)))
                // R16: a voicing on the change — the seventh and the third above the root — when
                // the chord has a seventh to state.
                if isChange, tones.count >= 4 {
                    for extra in [tones[3], tones[1]] {
                        drafts.append(Draft(pitch: clampToRegister(root + extra, .thundercat), start: onset,
                                            end: end, velocity: 78))
                    }
                }
            }
        }
        drafts += approaches(harmony: harmony, lineage: .thundercat, minimumMove: 1, totalBeats: beatsPerBar * Double(bars))
        return drafts
    }

    // MARK: Lineage C — the programmed low end

    /// R9: the bass *is* the kick. Every kick step becomes a note at the chord's root in the sub
    /// register, held to the next kick, so the two can never sustain against each other because
    /// they are one thing. No approaches, no ghosts: an 808 glides, it does not walk.
    private static func writeProgrammed(_ request: BassRequest, kicks: [Double], harmony: HarmonyMap,
                                        beatsPerBar: Double, bars: Int) -> [Draft] {
        let totalBeats = beatsPerBar * Double(bars)
        let onsets = kicks.isEmpty ? stride(from: 0, to: totalBeats, by: beatsPerBar).map { $0 } : kicks
        var drafts: [Draft] = []
        for (i, onset) in onsets.enumerated() {
            let chord = harmony.chord(at: onset)
            let pitch = place(chord.root, near: nil, in: .programmed)
            let next = i + 1 < onsets.count ? onsets[i + 1] : totalBeats
            let end = max(onset + 0.25, onset + (next - onset) * 0.92)
            drafts.append(Draft(pitch: pitch, start: onset, end: end, velocity: 110))
        }
        return drafts
    }

    // MARK: Shared arithmetic

    /// R14's budget, from density. Under 100 bpm a verse gets at most six attacks a bar in lineage
    /// A; B's ceiling is eight (G4's verse figure); faster tempos allow one more.
    static func attackBudget(density: Double, tempo: Double, lineage: BassLineage) -> Int {
        let ceiling: Int
        switch lineage {
        case .palladino: ceiling = tempo <= 100 ? 6 : 7
        case .thundercat: ceiling = tempo <= 100 ? 8 : 9
        case .programmed: ceiling = 16
        }
        return max(1, min(ceiling, Int((2 + density * Double(ceiling - 2)).rounded())))
    }

    /// The root's pitch in the lineage's register, nearest the last note when there was one so
    /// the line does not leap for no reason.
    static func place(_ root: PitchClass, near last: Int?, in lineage: BassLineage) -> Int {
        let pc = root.rawValue
        let candidates = stride(from: 0, through: 127, by: 12).map { $0 + pc }
            .filter { lineage.preferredRoot.contains($0) }
        guard !candidates.isEmpty else { return clampToRegister(pc + 36, lineage) }
        guard let last else { return candidates.min { abs($0 - 39) < abs($1 - 39) }! }
        return candidates.min { abs($0 - last) < abs($1 - last) }!
    }

    static func clampToRegister(_ midi: Int, _ lineage: BassLineage) -> Int {
        var m = midi
        while m > lineage.register.upperBound { m -= 12 }
        while m < lineage.register.lowerBound { m += 12 }
        return m
    }

    /// R13: an approach note a half-step below the new root on the last eighth before each change
    /// whose root moves by at least `minimumMove` semitones (measured as the nearer way round).
    static func approaches(harmony: HarmonyMap, lineage: BassLineage, minimumMove: Int,
                           totalBeats: Double) -> [Draft] {
        var drafts: [Draft] = []
        var previous = harmony.chord(at: 0).root
        for change in harmony.changes where change > 0 {
            let next = harmony.chord(at: change).root
            let move = abs(((next.rawValue - previous.rawValue + 18) % 12) - 6)
            if move >= minimumMove {
                let target = place(next, near: nil, in: lineage)
                drafts.append(Draft(pitch: clampToRegister(target - 1, lineage), start: change - 0.5,
                                    end: change, velocity: 92, displaced: false))
            }
            previous = next
        }
        // The loop's own wrap: the last chord back to the first.
        let first = harmony.chord(at: 0).root
        let move = abs(((first.rawValue - previous.rawValue + 18) % 12) - 6)
        if move >= minimumMove, totalBeats >= 1 {
            let target = place(first, near: nil, in: lineage)
            drafts.append(Draft(pitch: clampToRegister(target - 1, lineage), start: totalBeats - 0.5,
                                end: totalBeats - 0.05, velocity: 92, displaced: false))
        }
        return drafts
    }

    /// Kick onsets in beats, swung as the groove swings them.
    public static func kickOnsets(in groove: Groove, beatsPerBar: Double) -> [Double] {
        guard let pattern = groove.patterns.first(where: { $0.voice == .kick }) else { return [] }
        let stepBeats = beatsPerBar / Double(max(1, groove.stepsPerBar))
        let stepsPerBeat = Double(groove.stepsPerBar) / beatsPerBar
        var onsets: [Double] = []
        for (i, tier) in pattern.steps.enumerated() where tier != .rest {
            var t = Double(i) * stepBeats
            // The MPC swings the second sixteenth of each pair: at 75% it sits halfway to the next.
            if stepsPerBeat >= 4, i % 2 == 1 { t += groove.swing * 0.5 * stepBeats }
            onsets.append(t)
        }
        return onsets
    }
}

// MARK: - Harmony

/// The chords laid along the loop, cycled, so "the chord at beat 7" is one lookup.
public struct HarmonyMap: Hashable, Sendable {
    public struct Span: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var chord: Chord
    }
    public let spans: [Span]
    public let totalBeats: Double

    public init(chords: [ChordSpan], totalBeats: Double) {
        var spans: [Span] = []
        var t = 0.0
        var i = 0
        let usable = chords.filter { $0.beats > 0 }
        while t < totalBeats, !usable.isEmpty {
            let span = usable[i % usable.count]
            spans.append(Span(start: t, end: min(totalBeats, t + span.beats), chord: span.chord))
            t += span.beats
            i += 1
        }
        self.spans = spans
        self.totalBeats = totalBeats
    }

    public func chord(at beat: Double) -> Chord {
        spans.last { $0.start <= beat + 1e-9 }?.chord ?? spans.first?.chord ?? Chord(.c, .major)
    }

    /// Beats at which the chord changes, the loop's start included.
    public var changes: [Double] {
        var out: [Double] = []
        var previous: Chord?
        for span in spans {
            if span.chord != previous { out.append(span.start) }
            previous = span.chord
        }
        return out
    }
}

// MARK: - Randomness

/// xorshift64*, seeded. The writer's only source of variation, so a seed is a whole line.
struct BassRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
