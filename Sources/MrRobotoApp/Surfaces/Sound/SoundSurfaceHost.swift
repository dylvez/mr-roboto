import Foundation
import SongGraph

/// What the Sound surface needs from whatever is hosting it — and nothing else.
///
/// Three members, matching the three things `Surface` says a surface does: it **binds to a part**
/// (`selectedPart`), it **plays on touch** (`audition`), and an **edit produces a new version**
/// (`record`). The surface never mutates a version and never reaches for an engine directly.
///
/// This exists so the surface can be built and tested before A9's `AppState` lands. `AppState` is
/// expected to satisfy it as written — it is a `@MainActor` reference type with a selection, a way
/// to play a buffer, and the song graph — at which point this protocol becomes the seam rather than
/// the stand-in, and `SoundSurfaceStub` in the tests stays the offline host.
///
/// Note what is *not* here: re-rendering the kit on disk. A knob turn renders one voice with
/// `DrumSynthesizer.render`; catching the kit folder up with `SynthesizedKit.rerender` is the
/// host's business when it sees a new version, because the host is what owns the kit.
@MainActor
public protocol SoundSurfaceHost: AnyObject {

    /// The part version the surface opened against, or `nil` when nothing is selected — in which
    /// case the surface starts a new part from a machine preset.
    var selectedPart: PartVersion? { get }

    /// Play this now. No agent round trip, no scheduling: the Komma lesson is that the payoff has
    /// to be in the first five seconds, so an audition is fire-and-forget and may be interrupted by
    /// the next one.
    func audition(_ audition: SoundAudition)

    /// Take a new, immutable part version. The surface builds it with `PartVersion.deriving` (or
    /// starts a part when there was none) and hands it over; where it goes is the host's business.
    ///
    /// - Returns: `false` when the host refused it, so the surface can keep the edit as a draft
    ///   rather than pretending it was kept.
    @discardableResult
    func record(_ version: PartVersion) -> Bool
}

/// One rendered hit, ready to play.
///
/// Mono float samples because that is what `DrumSynthesizer.render` produces and what a drum voice
/// is; the host widens it if its output does.
public struct SoundAudition: Hashable, Sendable {

    /// Mono float samples, peaking below 1.0.
    public var samples: [Float]
    public var sampleRate: Double

    /// What made it, for a host that wants to label or cache: `"tr808 kick"`.
    public var label: String

    /// True when the degradation chain was bypassed for this render — the dry half of an A/B.
    ///
    /// The chain normalises every saturation curve by its slope at the origin, so `|y| <= |x|` at
    /// any drive and the chain can only ever compress. That is what makes the comparison fair, and
    /// it is only worth anything if the dry side really is untouched: a dry audition is the
    /// synthesizer's own samples, not the chain set to `.clean`.
    public var isDry: Bool

    public init(samples: [Float], sampleRate: Double, label: String, isDry: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.label = label
        self.isDry = isDry
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}
