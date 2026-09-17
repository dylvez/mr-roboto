import Foundation

/// Swing as a delay applied to the odd steps of a groove.
///
/// ## The one formula
///
/// Linn's swing — the thing every MPC, SP and DAW copies — delays the *second* sixteenth of each
/// eighth-note pair and leaves the first alone. Roger Linn: "I merely delay the second 16th note
/// within each 8th note. In other words, I delay all the even-numbered 16th notes within the beat"
/// (even by his 1-based count, i.e. `step % 2 == 1` by ours). Nothing else moves.
///
/// The amount is quoted as a **percentage**: the share of the eighth note that the *first* sixteenth
/// gets. 50% is straight (equal halves), 66.67% is a perfect triplet (2/3 then 1/3), and 75% is the
/// maximum an MPC offers (the second sixteenth lands halfway to the next one — a dotted-eighth /
/// thirty-second pair). Percentages above 75 are not "more swing", they are a different note value,
/// which is why the machines stop there.
///
/// ## Percent ↔ factor
///
/// `SongGraph.Groove.swing` stores a 0…1 factor, and `groove-theory`'s working engine applies it as
///
/// ```js
/// const swingOffset = (step % 2 === 1) ? swing * stepDuration * 0.5 : 0;   // AudioEngine.ts
/// ```
///
/// Setting that equal to the percentage definition — the odd step should land at `percent/100` of
/// the two-step pair, i.e. `offset = 2·d·(P/100) − d` — gives
///
/// ```
/// factor  = (percent − 50) / 25
/// percent = 50 + 25 · factor
/// offset  = factor · stepDuration · 0.5
/// ```
///
/// so the ported formula *is* the MPC mapping, and the stored 0…1 factor spans exactly the MPC's
/// own 50–75% range. Landmarks: `0.00 = 50%` straight, `0.16 = 54%` (Linn's "loosen a straight
/// beat without it sounding like swing"), `0.24 = 56%`, `0.32 = 58%`, `0.40 = 60%`, `0.48 = 62%`
/// ("looser than perfect swing at 90 BPM"), `0.667 = 66.67%` triplet, `1.00 = 75%` maximum.
///
/// Note this corrects the doc comment on `Groove.swing`, which says 1 is "full triplet swing":
/// triplet is 2/3, and 1 is the MPC maximum. The UI shows `percent`; the graph stores `factor`.
///
/// ## Resolution
///
/// Swing is relative to the groove's own step grid, which is the machine's quantize resolution:
/// a 16-steps-per-bar groove in 4/4 swings sixteenths, a 32-steps-per-bar groove swings
/// thirty-seconds. A groove whose steps are already triplets (12 per bar in 4/4, our Shuffle)
/// carries the shuffle in its steps and wants `swing = .straight`.
///
/// Sources: Roger Linn interviewed in Attack Magazine,
/// <https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/>;
/// MPC swing range 50–75%, <https://padwolf.app/learn/mpc-swing-explained/>.
public struct Swing: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Straight — both halves of the pair equal.
    public static let minimumPercent: Double = 50
    /// The maximum an MPC offers: the odd step halfway to the next step.
    public static let maximumPercent: Double = 75
    /// A perfect triplet: 2/3 then 1/3.
    public static let tripletPercent: Double = 200.0 / 3.0

    /// The 0…1 value `SongGraph.Groove.swing` stores.
    public var factor: Double

    /// - Parameter factor: clamped to 0…1.
    public init(factor: Double) {
        self.factor = Swing.clamp(factor, 0, 1)
    }

    /// - Parameter percent: clamped to 50…75, the range the machines offer.
    public init(percent: Double) {
        self.init(factor: (Swing.clamp(percent, Swing.minimumPercent, Swing.maximumPercent) - 50) / 25)
    }

    /// The figure a UI shows: 50 straight, 66.67 triplet, 75 maximum.
    public var percent: Double { 50 + 25 * factor }

    public static let straight = Swing(factor: 0)
    public static let triplet = Swing(percent: Swing.tripletPercent)
    /// Linn's "loosens a straight sixteenth beat without sounding like swing".
    public static let loose = Swing(percent: 54)

    /// True for the steps swing moves: the second of each pair.
    public func isSwung(step: Int) -> Bool { step % 2 != 0 }

    /// Seconds to delay `step` by, given the length of one step at that point in the timeline.
    ///
    /// Ported verbatim from `groove-theory/src/audio/AudioEngine.ts`; see the type's documentation
    /// for why this is also the MPC percentage mapping.
    public func offset(forStep step: Int, stepDuration: Double) -> Double {
        isSwung(step: step) ? factor * stepDuration * 0.5 : 0
    }

    public var description: String {
        String(format: "%.4g%%", percent)
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x.isFinite ? Swift.min(hi, Swift.max(lo, x)) : lo
    }
}
