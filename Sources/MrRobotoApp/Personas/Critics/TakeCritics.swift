import Foundation
import MusicTheory
import Performance
import SongGraph

// M5 R8: the two critics that read a take. Each flag names a bar and a number — cents or
// milliseconds — and carries two fixes, one of which is always the retake. Nothing here touches
// the take: a fix taken is a new version with the take as its parent.

/// A take, as the critics are handed it.
public struct TakeReview: Sendable {
    public var analysis: TakeAnalysis
    /// Under this, nothing is said.
    public var noticeableCents: Double
    public var noticeableMS: Double
    /// How many flags each critic raises at most, worst first.
    public var limit: Int

    public init(analysis: TakeAnalysis, noticeableCents: Double = 10, noticeableMS: Double = 20, limit: Int = 4) {
        self.analysis = analysis
        self.noticeableCents = noticeableCents
        self.noticeableMS = noticeableMS
        self.limit = limit
    }
}

public protocol TakeCritic: Critic {
    func review(_ input: TakeReview) -> [Finding]
}

/// A sung note past the noticeable line from the nearest note in the key.
public struct PitchDriftCritic: TakeCritic {
    public init() {}
    public var id: CriticID { .pitchDrift }
    public var name: String { "Pitch drift" }
    public var persona: PersonaID { .engineer }
    public var checks: String { "every sung note's distance from the nearest note in the key, in cents; flagged past 10" }

    public func review(_ input: TakeReview) -> [Finding] {
        let a = input.analysis
        let drifting = a.drifting(over: input.noticeableCents).sorted { abs($0.centsFromKey) > abs($1.centsFromKey) }.prefix(input.limit)
        return drifting.map { note in
            let cents = note.centsFromKey
            let signed = String(format: "%+.0f", cents)
            let keyName = a.key.map { " in \($0)" } ?? ""
            return Finding(
                critic: id, criticName: name, persona: persona,
                subject: .bar(note.bar),
                locus: Locus(bar: note.bar, beat: note.beat, start: note.start - a.alignmentSeconds, end: note.end - a.alignmentSeconds),
                headline: "Bar \(note.bar + 1), \(signed) cents",
                why: "The note reads \(signed) cents \(cents > 0 ? "sharp" : "flat") of \(note.pitchName)\(keyName). "
                    + "Past \(Int(input.noticeableCents)) it is heard as off the note rather than as the note.",
                severity: abs(cents) >= 25 ? .warn : .note,
                measurement: Measurement(.takePitchCents, measured: cents,
                                         threshold: .between(.takePitchCents, -input.noticeableCents, input.noticeableCents, unit: "cents"),
                                         unit: "cents"),
                first: Fix("shift-\(note.index)", title: String(format: "Correct it by %+.0f cents", -cents),
                           detail: "Formants held, so the vowel stays; the timbre moves a little with the pitch. A new version; the take stays.",
                           change: .shiftNote(index: note.index, cents: -cents)),
                second: Fix("retake-\(note.bar)", title: "Retake bar \(note.bar + 1)",
                            detail: "The honest fix. The Booth punches in on the section; the new take sits beside this one.",
                            change: .retake(bar: note.bar)))
        }
    }
}

/// A sung onset past the noticeable line from the grid.
public struct TimingCritic: TakeCritic {
    public init() {}
    public var id: CriticID { .timing }
    public var name: String { "Timing" }
    public var persona: PersonaID { .lyricist }
    public var checks: String { "every sung onset's distance from the nearest sixteenth of the grid, in milliseconds; flagged past 20" }

    public func review(_ input: TakeReview) -> [Finding] {
        let a = input.analysis
        let off = (a.late(over: input.noticeableMS) + a.early(over: input.noticeableMS)).sorted { abs($0.timingMS) > abs($1.timingMS) }.prefix(input.limit)
        return off.map { note in
            let ms = note.timingMS
            let late = ms > 0
            return Finding(
                critic: id, criticName: name, persona: persona,
                subject: .bar(note.bar),
                locus: Locus(bar: note.bar, beat: note.beat, start: note.start - a.alignmentSeconds, end: note.end - a.alignmentSeconds),
                headline: String(format: "Bar %d came in %.0f ms %@", note.bar + 1, abs(ms), late ? "late" : "early"),
                why: String(format: "The word lands %.0f ms %@ the sixteenth it belongs to. Under %d it reads as feel; past it, as a miss.",
                            abs(ms), late ? "after" : "before", Int(input.noticeableMS)),
                severity: abs(ms) >= 50 ? .warn : .note,
                measurement: Measurement(.takeTimingMS, measured: ms,
                                         threshold: .between(.takeTimingMS, -input.noticeableMS, input.noticeableMS, unit: "ms"),
                                         unit: "ms"),
                first: Fix("nudge-\(note.index)", title: String(format: "Move it %.0f ms %@", abs(ms), late ? "earlier" : "later"),
                           detail: "The note slides onto the grid with 10 ms crossfades at each end. A new version; the take stays.",
                           change: .nudgeNote(index: note.index, milliseconds: -ms)),
                second: Fix("retake-\(note.bar)", title: "Retake bar \(note.bar + 1)",
                            detail: "The honest fix. The Booth punches in on the section; the new take sits beside this one.",
                            change: .retake(bar: note.bar)))
        }
    }
}
