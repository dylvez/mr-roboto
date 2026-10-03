import Foundation
import Performance
import SongGraph

// M6 X7: the three critics that read a mix. Masking between two strips, a true peak over the
// ceiling, a master off its target. Every fix is a mix move the Check records as a version.
// A fourth reads what the mix is made of: a chop that is quiet at its source.

/// A chop the song plays whose bar is far under where an instrument sits, and that has no level
/// of its own yet (`ChopLevel`).
public struct QuietChop: Hashable, Sendable {
    public var part: PartID
    public var label: String
    /// Its bar's loudest tenth of a second, dBFS.
    public var loudnessDBFS: Double
    /// What levelling it would bring it up by.
    public var gainDB: Double

    public init(part: PartID, label: String, loudnessDBFS: Double, gainDB: Double) {
        self.part = part
        self.label = label
        self.loudnessDBFS = loudnessDBFS
        self.gainDB = gainDB
    }
}

/// A mix reading, as the critics are handed it.
public struct MixReview: Sendable {
    public var observation: MixObservation
    public var master: Master
    /// Under this gap, two strips share a band.
    public var noticeableDB: Double
    /// The loudness window either side of the target.
    public var windowLU: Double
    public var limit: Int
    /// The chops the song plays that are quiet at their source.
    public var quietChops: [QuietChop]

    public init(observation: MixObservation, master: Master, noticeableDB: Double = 6, windowLU: Double = 2, limit: Int = 4,
                quietChops: [QuietChop] = []) {
        self.observation = observation
        self.master = master
        self.noticeableDB = noticeableDB
        self.windowLU = windowLU
        self.limit = limit
        self.quietChops = quietChops
    }
}

public protocol MixCritic: Critic {
    func review(_ input: MixReview) -> [Finding]
}

/// A chop quiet at its source: levelled at the chop, not made up in the mix.
///
/// The session that asked for this: a bar of a stem the separator had left nearly empty, played
/// as recorded. The song bounced 19 LU under its target, the only fix on offer was the master, and
/// the master went up 18.8 dB — after which every drum machine added to the song was that much
/// too loud. The cause was one part, and it has a level of its own.
public struct QuietSourceCritic: MixCritic {
    public init() {}
    public var id: CriticID { .quietSource }
    public var name: String { "Quiet at its source" }
    public var persona: PersonaID { .engineer }
    public var checks: String { "every chop the song plays, by its bar's loudest moment, against where an instrument sits" }

    public func review(_ input: MixReview) -> [Finding] {
        input.quietChops.prefix(input.limit).map { chop in
            Finding(
                critic: id, criticName: name, persona: persona,
                subject: .mix("\(chop.label), at its source"),
                locus: Locus(bar: nil, beat: nil, start: 0, end: 0),
                headline: String(format: "%@ is quiet at its source: %.0f dBFS at its loudest", chop.label, chop.loudnessDBFS),
                why: String(format: "An instrument's loudest moment sits at %.0f dBFS. Made up on the master, everything added to the song afterwards is that much too loud; made up on a strip, the next chop of the same bar is quiet again.",
                            ChopLevel.targetDBFS),
                severity: .warn,
                measurement: Measurement(.peakDBFS, measured: chop.loudnessDBFS,
                                         threshold: .atLeast(.peakDBFS, ChopLevel.targetDBFS - ChopLevel.leastDB, unit: "dBFS"), unit: "dBFS"),
                first: Fix("level-chop", title: String(format: "Level %@ %+.0f dB, at the chop", chop.label, chop.gainDB),
                           detail: "A version of the chop: its loop, its pads and every groove on its slices come up together. The mix does not move.",
                           change: .levelChop(part: chop.part, gainDB: chop.gainDB)),
                second: Fix("leave", title: "Leave it as recorded",
                            detail: "A quiet bar under everything else is a choice.",
                            change: .accept))
        }
    }
}

/// Two strips within the noticeable gap in a band: one of them owns it, and the other moves.
public struct MaskingCritic: MixCritic {
    public init() {}
    public var id: CriticID { .masking }
    public var name: String { "Masking" }
    public var persona: PersonaID { .engineer }
    public var checks: String { "every pair of strips, band by band; flagged within 6 dB where both have energy" }

    public func review(_ input: MixReview) -> [Finding] {
        let pairs = MixObservation.masking(input.observation.strips, noticeable: input.noticeableDB).prefix(input.limit)
        return pairs.map { pair in
            let cut = -(input.noticeableDB - pair.gapDB).rounded()
            let hz = pair.centreHz.rounded()
            return Finding(
                critic: id, criticName: name, persona: persona,
                subject: .mix("\(pair.aLabel) and \(pair.bLabel) at \(pair.bandName) Hz"),
                locus: Locus(bar: nil, beat: nil, start: 0, end: 0),
                headline: String(format: "%@ and %@ within %.0f dB at %@ Hz", pair.aLabel, pair.bLabel, pair.gapDB, pair.bandName),
                why: String(format: "%@ owns %@ Hz by %.0f dB; under %.0f the two read as one sound and neither owns the band.",
                            pair.louderLabel, pair.bandName, pair.gapDB, input.noticeableDB),
                severity: pair.gapDB < 3 ? .warn : .note,
                measurement: Measurement(.lowEndSeparationDB, measured: pair.gapDB,
                                         threshold: .atLeast(.lowEndSeparationDB, input.noticeableDB, unit: "dB"), unit: "dB"),
                first: Fix("cut-quieter", title: String(format: "Cut %@ %.0f dB at %.0f Hz", pair.quieterLabel, -cut, hz),
                           detail: "The part that does not own the band gives it up: room, not level. A mix version; step back from Parts.",
                           change: .mixStrip(part: pair.quieter, gainDB: nil, bandHz: hz, bandDB: cut)),
                second: Fix("cut-louder", title: String(format: "Cut %@ %.0f dB at %.0f Hz instead", pair.louderLabel, -cut, hz),
                            detail: "The other way round, when the quieter part is the one that should own it. A mix version.",
                            change: .mixStrip(part: pair.louder, gainDB: nil, bandHz: hz, bandDB: cut)))
        }
    }
}

/// The true peak over the ceiling.
public struct OverCeilingCritic: MixCritic {
    public init() {}
    public var id: CriticID { .overCeiling }
    public var name: String { "Over the ceiling" }
    public var persona: PersonaID { .engineer }
    public var checks: String { "the bounce's true peak against the master's ceiling" }

    public func review(_ input: MixReview) -> [Finding] {
        guard let truePeak = input.observation.truePeakDBTP, truePeak > input.master.ceilingDBTP + 0.05 else { return [] }
        let over = truePeak - input.master.ceilingDBTP
        return [Finding(
            critic: id, criticName: name, persona: persona,
            subject: .mix("the master's ceiling"),
            locus: Locus(bar: nil, beat: nil, start: 0, end: 0),
            headline: String(format: "True peak %.1f dBTP, %.1f over the ceiling", truePeak, over),
            why: String(format: "The ceiling is %.1f dBTP and the bounce reads %.1f; the encoder clips what is over.", input.master.ceilingDBTP, truePeak),
            severity: .warn,
            measurement: Measurement(.peakDBFS, measured: truePeak, threshold: .atMost(.peakDBFS, input.master.ceilingDBTP, unit: "dBTP"), unit: "dBTP"),
            first: Fix("master-down", title: String(format: "Bring the master down %.1f dB", over),
                       detail: "Gain before the limiter; the mix keeps its crest. A mix version.",
                       change: .mixMaster(gainDB: -over, ceilingDBTP: nil)),
            second: Fix("ceiling", title: String(format: "Hold the ceiling at %.1f dBTP", input.master.ceilingDBTP),
                        detail: "Re-applies the limiter over the next bounce and export. A mix version.",
                        change: .mixMaster(gainDB: nil, ceilingDBTP: input.master.ceilingDBTP)))]
    }
}

/// The integrated loudness off the target.
public struct HotMasterCritic: MixCritic {
    public init() {}
    public var id: CriticID { .hotMaster }
    public var name: String { "Off the target" }
    public var persona: PersonaID { .engineer }
    public var checks: String { "the bounce's integrated loudness against the master's target, within 2 LU" }

    public func review(_ input: MixReview) -> [Finding] {
        let lufs = input.observation.integratedLUFS
        guard lufs.isFinite, abs(lufs - input.master.targetLUFS) > input.windowLU else { return [] }
        let gap = input.master.targetLUFS - lufs
        // Under the target with a chop quiet at its source: that is the cause, and the master is
        // read again once it is levelled. One move at a time.
        if gap > 0, !input.quietChops.isEmpty { return [] }
        return [Finding(
            critic: id, criticName: name, persona: persona,
            subject: .mix("the master's loudness"),
            locus: Locus(bar: nil, beat: nil, start: 0, end: 0),
            headline: String(format: "%.1f LUFS, %.0f LU %@ the target", lufs, abs(gap), gap > 0 ? "under" : "over"),
            why: String(format: "The target is %.0f LUFS; the platforms turn a %@ master %@, and a hot one only loses its crest.",
                        input.master.targetLUFS, gap > 0 ? "quiet" : "loud", gap > 0 ? "up at the cost of the noise floor" : "down"),
            severity: abs(gap) > 4 ? .warn : .note,
            measurement: Measurement(.integratedLUFS, measured: lufs,
                                     threshold: .between(.integratedLUFS, input.master.targetLUFS - input.windowLU, input.master.targetLUFS + input.windowLU, unit: "LUFS"),
                                     unit: "LUFS"),
            first: Fix("master-gain", title: String(format: "Move the master %+.1f dB", gap),
                       detail: "Gain before the limiter, by the gap. A mix version; read again after.",
                       change: .mixMaster(gainDB: gap, ceilingDBTP: nil)),
            second: Fix("leave", title: "Leave it: deliver as it is",
                        detail: "The platforms normalise; a quiet master with its crest is a choice.",
                        change: .accept))]
    }
}
