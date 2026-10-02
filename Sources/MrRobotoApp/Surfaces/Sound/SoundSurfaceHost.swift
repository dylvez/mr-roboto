import Foundation
import Instrument
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
/// `DrumSynthesizer.render`; catching the kit up is the host's business when it sees a new
/// version, because the host is what owns the kit. The app's host does it by building every kit
/// from the machine as the song has shaped it (`SongPlayback.shaped`).
///
/// The four members after `dustLever` are the song's side of a drum voice: which machine the song
/// plays, what it has kept of a voice, and whether a voice is a recording. Each has a default that
/// says "no song", so a host with none is still the whole of the first three.
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

    /// The newest version of a part in the song, so a new chain goes on what the Grid or the lane
    /// kept since this surface opened, not under it.
    func newest(of part: PartID) -> PartVersion?

    /// The dry sound of a sample or a groove — the part with **no chain on it at all**, whatever
    /// the version carries — for the surface to put through the chain it is editing. A chop is its
    /// bar of the record; a groove is one pass bounced on the song's machine.
    ///
    /// Asynchronous because it reads a file or renders a bounce; called once per binding, never on
    /// the touch path. A host that cannot render parts throws, and the surface says so.
    func dryAudio(of version: PartVersion) async throws -> SoundAudition

    /// The `dust` lever the Director hung on this surface, 0…1, when it hung one. A Sound surface
    /// opened on a sample or a groove with a lever starts its draft at `Dust.lever(amount)` — the same
    /// pass the Compare's `dust` lever plays at that amount.
    var dustLever: Double? { get }

    /// The drum machine the song plays, by id: what a surface opened on no voice opens on. Nil
    /// when there is no song, and the surface opens on the TR-808.
    var songMachine: String? { get }

    /// The newest edit of this voice of this machine the song has kept, when it has kept one. A
    /// voice opens at it, and the next edit is its next version.
    func keptVoice(_ voice: SynthVoiceKind, on machine: String) -> PartVersion?

    /// What the recording that plays this voice is called, when one does: a recorded kit's kick,
    /// a conga from the hand percussion in use. Nil is a synthesized voice.
    func recording(of voice: SynthVoiceKind, on machine: String) -> String?

    /// One hit of a voice as the song's kit plays it — `machine` shaped as the song has kept it —
    /// which for a recorded voice is the recording at the level the kit brings it to. Dry: with
    /// no chain of the voice's own on it, because the surface puts the draft's chain on.
    /// Asynchronous because it builds the kit when nobody has yet. A host with no kit throws.
    func kitHit(of voice: SynthVoiceKind, on machine: SynthMachine) async throws -> SoundAudition
}

public extension SoundSurfaceHost {
    public func newest(of part: PartID) -> PartVersion? { nil }
    var songMachine: String? { nil }
    func keptVoice(_ voice: SynthVoiceKind, on machine: String) -> PartVersion? { nil }
    func recording(of voice: SynthVoiceKind, on machine: String) -> String? { nil }
    func kitHit(of voice: SynthVoiceKind, on machine: SynthMachine) async throws -> SoundAudition {
        throw SoundSurfaceUnavailable(what: "this host has no kit to play the \(voice.rawValue) on")
    }
    func dryAudio(of version: PartVersion) async throws -> SoundAudition {
        throw SoundSurfaceUnavailable(what: "this host cannot render a \(version.type.rawValue) to put through the chain")
    }

    var dustLever: Double? { nil }
}

/// Why the Sound surface could not get at the thing it was asked to dirty. Carried verbatim.
public struct SoundSurfaceUnavailable: Error, CustomStringConvertible, Sendable {
    public let what: String
    public init(what: String) { self.what = what }
    public var description: String { what }
}

/// One rendered hit, ready to play.
///
/// Mono float samples because that is what `DrumSynthesizer.render` produces and what a drum voice
/// is; the host widens it if its output does.
public struct SoundAudition: Hashable, Sendable {

    /// Planar float channels at `sampleRate`. One channel for a drum voice; a chop keeps the
    /// channels of the record it was cut from.
    public var planar: [[Float]]
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
        self.init(planar: [samples], sampleRate: sampleRate, label: label, isDry: isDry)
    }

    public init(planar: [[Float]], sampleRate: Double, label: String, isDry: Bool) {
        self.planar = planar
        self.sampleRate = sampleRate
        self.label = label
        self.isDry = isDry
    }

    /// The first channel: all of a drum voice, and the left of a stereo chop.
    public var samples: [Float] { planar.first ?? [] }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}
