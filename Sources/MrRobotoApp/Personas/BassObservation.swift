import Foundation
import MusicTheory
import Performance
import SongGraph

/// Everything the Bassist measures about a bass line, in the units its rules are written in.
///
/// Read from a `Bassline` against the groove it sits under, at a tempo, with the harmony it was
/// written to. Like `GrooveObservation`, this is arithmetic over stored values: nothing renders.
/// The writer is never trusted — the Bassist reads what it wrote back through this and judges it
/// as it would judge a line anyone else wrote.
public struct BassObservation: Hashable, Sendable {

    public var label: String
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var bars: Int
    /// The bass sound the line plays through, by voice id.
    public var sound: String

    /// Milliseconds behind (positive) or ahead of (negative) the nearest kick, one per onset, in
    /// onset order. A bass with no kick to sit against measures against the beat grid instead.
    public var kickOffsetsMS: [Double]
    /// Sounding length over the interval to the next onset, one per note.
    public var lengthRatios: [Double]
    public var restRatio: Double
    public var syncopation: Double
    public var chromaticApproachRate: Double
    /// Root moves of a third or more, so a rate of 0 over 0 moves reads as "nothing to approach".
    public var largeRootMoves: Int
    public var ghostRate: Double
    public var registerLow: Int
    public var registerHigh: Int
    public var attacksPerBar: Double
    public var noteOffOnBeatRate: Double
    /// Bars whose downbeat carries an attack, over all bars: R7's "never leaves the downbeat alone".
    public var downbeatCoverage: Double
    /// Whether every other onset lands early: the one early pattern R2 allows.
    public var earlyAlternation: Bool
    /// From the groove: how far the hats and the kick have themselves moved, in milliseconds.
    public var hatLagMS: Double
    public var kickLagMS: Double
    /// The kick's T60 in seconds, when the kit is known. 0 when it is not.
    public var kickDecaySeconds: Double
    /// Whether the line sounds any two notes at once.
    public var hasVoicings: Bool
    /// How many distinct simultaneous pitch-class sets of three or more it states.
    public var distinctVoicings: Int

    // MARK: Derived

    public var medianKickOffsetMS: Double { Self.median(kickOffsetsMS) }
    public var maxKickOffsetMS: Double {
        kickOffsetsMS.max(by: { abs($0) < abs($1) }) ?? 0
    }
    public var medianLengthRatio: Double { Self.median(lengthRatios) }
    public var isSub: Bool { sound == "sub" }

    /// The reading of one feature.
    public func value(of feature: Feature) -> Double? {
        switch feature {
        case .bassKickOffsetMS: return medianKickOffsetMS
        case .bassMaxOffsetMS: return maxKickOffsetMS
        case .bassNoteLengthRatio: return medianLengthRatio
        case .bassRestRatio: return restRatio
        case .bassSyncopation: return syncopation
        case .bassChromaticApproachRate: return chromaticApproachRate
        case .bassGhostRate: return ghostRate
        case .bassRegisterLow: return Double(registerLow)
        case .bassRegisterHigh: return Double(registerHigh)
        case .bassAttacksPerBar: return attacksPerBar
        case .bassNoteOffOnBeatRate: return noteOffOnBeatRate
        case .bassDownbeatCoverage: return downbeatCoverage
        case .bassEarlyAlternation: return earlyAlternation ? 1 : 0
        case .referenceLagMS: return hatLagMS
        case .kickLagMS: return kickLagMS
        case .kickDecaySeconds: return kickDecaySeconds
        case .bassIsSub: return isSub ? 1 : 0
        case .tempoBPM: return tempo
        default: return nil
        }
    }

    // MARK: Construction

    /// Read a bass line against a groove.
    ///
    /// - Parameters:
    ///   - chords: the harmony the line was written to, for the chromatic-approach reading.
    ///   - options: the groove's render options, for where the hats and kick actually sit.
    ///   - kickDecaySeconds: the kit's kick T60 when known.
    public init(label: String, bassline: Bassline, groove: Groove, chords: [ChordSpan],
                tempo: Double, timeSignature: TimeSignature = .fourFour,
                options: GrooveRenderOptions = GrooveRenderOptions(), kickDecaySeconds: Double = 0) {
        self.label = label
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.bars = max(1, groove.bars)
        self.sound = bassline.sound ?? "finger"
        self.kickDecaySeconds = kickDecaySeconds

        let beatsPerBar = Double(max(1, timeSignature.beatsPerBar))
        let totalBeats = beatsPerBar * Double(bars)
        let msPerBeat = tempo > 0 ? 60_000 / tempo : 0
        let stepBeats = beatsPerBar / Double(max(1, groove.stepsPerBar))
        let stepMS = stepBeats * msPerBeat

        // Where the groove's voices actually sit, in ms.
        hatLagMS = (options.voices[.closedHat]?.timingOffset ?? 0) * stepMS
        kickLagMS = (options.voices[.kick]?.timingOffset ?? 0) * stepMS
        let kicks = BassWriter.kickOnsets(in: groove, beatsPerBar: beatsPerBar)
            .map { $0 + (options.voices[.kick]?.timingOffset ?? 0) * stepBeats }

        let notes = bassline.notes.sorted { ($0.start, $0.pitch.midi) < ($1.start, $1.pitch.midi) }
        // Distinct onsets: a voicing is one attack.
        var onsets: [Double] = []
        for note in notes where onsets.last.map({ abs($0 - note.start) > 1e-6 }) ?? true { onsets.append(note.start) }
        let attacks = onsets.count
        // A ghost is a muted attack, not a placement: it says nothing about where the line sits.
        func isGhost(_ onset: Double) -> Bool {
            notes.filter { abs($0.start - onset) < 1e-6 }.allSatisfy { $0.velocity < 56 && $0.duration <= 0.25 }
        }
        let placed = onsets.filter { !isGhost($0) }

        // Kick offsets, in ms: each placed onset against whichever is nearer, the nearest kick or
        // the nearest eighth-note line, the kick winning a tie. A note 40 ms behind a kick is 40
        // behind it (the grid line is further); a pickup on the and of four is on its line even
        // when a swung kick sits a fifth of a beat before it.
        var offsets: [Double] = []
        for onset in placed {
            let gridLine = (onset * 2).rounded() / 2
            var reference = gridLine
            if let nearestKick = kicks.min(by: { abs($0 - onset) < abs($1 - onset) }),
               abs(nearestKick - onset) <= abs(gridLine - onset) + 1e-9 {
                reference = nearestKick
            }
            offsets.append((onset - reference) * msPerBeat)
        }
        kickOffsetsMS = offsets

        // Early alternation: the signs of successive onsets' offsets alternate, with the early ones
        // no more than 25 ms early.
        var alternates = offsets.count >= 4
        for (i, offset) in offsets.enumerated() where alternates {
            let expectEarly = i % 2 == 1
            // A hair of tolerance either side: −25.0000001 is 25 ms early, not 26.
            if expectEarly { alternates = offset < 0 && offset >= -25.5 } else { alternates = offset >= -0.5 }
        }
        earlyAlternation = alternates

        // Length ratios: sounding length over the interval to the next onset.
        var ratios: [Double] = []
        for (i, onset) in onsets.enumerated() {
            let next = i + 1 < onsets.count ? onsets[i + 1] : totalBeats
            let longest = notes.filter { abs($0.start - onset) < 1e-6 }.map(\.duration).max() ?? 0
            let interval = max(1e-6, next - onset)
            ratios.append(min(1, longest / interval))
        }
        lengthRatios = ratios

        // Rest: the loop minus the union of sounding spans.
        var sounding = 0.0
        var cursor = 0.0
        for note in notes {
            let start = max(cursor, note.start)
            let end = min(totalBeats, note.end)
            if end > start { sounding += end - start; cursor = end }
        }
        restRatio = totalBeats > 0 ? max(0, 1 - sounding / totalBeats) : 0

        // Syncopation: onsets not on a quarter, with a sixteenth of tolerance for the lag.
        let tolerance = 0.125
        let off = onsets.filter { abs($0 - $0.rounded()) > tolerance }.count
        syncopation = attacks > 0 ? Double(off) / Double(attacks) : 0

        // Chromatic approach: for each root move of ≥3 semitones, is there a note a half-step
        // below the new root in the last beat before the change?
        let harmony = HarmonyMap(chords: chords, totalBeats: totalBeats)
        var moves = 0
        var approached = 0
        var previous = harmony.chord(at: 0).root
        let changes = harmony.changes.filter { $0 > 0 } + (harmony.spans.count > 1 ? [totalBeats] : [])
        for change in changes {
            let next = change >= totalBeats ? harmony.chord(at: 0).root : harmony.chord(at: change).root
            let move = abs(((next.rawValue - previous.rawValue + 18) % 12) - 6)
            if move >= 3 {
                moves += 1
                let below = (next.rawValue + 11) % 12
                if notes.contains(where: { $0.start >= change - 1 && $0.start < change && $0.pitch.pitchClass.rawValue == below }) {
                    approached += 1
                }
            }
            previous = next
        }
        largeRootMoves = moves
        chromaticApproachRate = moves > 0 ? Double(approached) / Double(moves) : 0

        let ghosts = attacks - placed.count
        ghostRate = attacks > 0 ? Double(ghosts) / Double(attacks) : 0

        // R7: bars whose downbeat has a placed attack within a sixteenth of it.
        var covered = 0
        for bar in 0..<bars {
            let downbeat = Double(bar) * beatsPerBar
            if placed.contains(where: { abs($0 - downbeat) <= 0.25 }) { covered += 1 }
        }
        downbeatCoverage = Double(covered) / Double(max(1, bars))

        registerLow = notes.map(\.pitch.midi).min() ?? 0
        registerHigh = notes.map(\.pitch.midi).max() ?? 0
        attacksPerBar = Double(attacks) / Double(max(1, bars))

        // Note-offs within 15 ms of a beat line, over the placed notes: a ghost's note-off is the
        // mute itself.
        let soundingNotes = notes.filter { !isGhost($0.start) }
        let onBeat = soundingNotes.filter { abs($0.end - $0.end.rounded()) * msPerBeat <= 15 }.count
        noteOffOnBeatRate = soundingNotes.isEmpty ? 0 : Double(onBeat) / Double(soundingNotes.count)

        // Voicings: pitch-class sets sounded together.
        var sets = Set<Set<Int>>()
        for onset in onsets {
            let together = Set(notes.filter { abs($0.start - onset) < 1e-6 }.map { $0.pitch.pitchClass.rawValue })
            if together.count >= 2 { sets.insert(together) }
        }
        hasVoicings = !sets.isEmpty
        distinctVoicings = sets.filter { $0.count >= 3 }.count
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
