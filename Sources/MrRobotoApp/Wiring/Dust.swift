import Foundation
import Instrument
import MusicTheory
import Performance
import SongGraph

/// One definition of what "dust" means in this app, shared by everything that makes a part dusty or
/// plays one.
///
/// Four places used to have their own idea of it — the Sound surface's chain, the Compare's `dust`
/// lever, the transport (which had none) and the audition service (which played whatever floats it
/// was handed). They now agree because they all go through here:
///
/// * **`lever(_:)`** is the dust lever as a chain: the SP-1200 preset, its seed intact, at a mix of
///   the lever's amount. The Compare's `dust` lever, the Director's `dust` lever on a Sound surface
///   and a Sound surface pressing `sp1200` at full mix are therefore the same pass.
/// * **`render(_:sampleRate:passes:)`** is how a pass becomes sound: `DegradeChain.rendered`, fresh
///   chain per pass, latency-compensated, seeded from the stored seed. Every caller that plays a
///   dusty part plays it through this and nothing else, so an audition, a transport bounce and a
///   Compare row of the same version are the same samples.
/// * **`review(…)`** is how a dusty part meets the critics: the top pass is the chain under review
///   and every pass beneath it is a chain the source has *already* been through, which is exactly
///   what `DegradeStackCritic`'s second-quantiser check reads.
enum Dust {

    /// The preset "dustier" means in this instrument's own vocabulary — twelve bits and a 26 kHz
    /// hold — rather than a number invented for a lever.
    static let leverPreset = DegradeSettings.Preset.sp1200

    /// The dust lever at `amount` (0…1) as chain settings: the lever preset at that mix.
    static func lever(_ amount: Double) -> DegradeSettings {
        settings(leverPreset, mix: amount)
    }

    /// The dust lever at `amount` as a stored pass.
    static func pass(_ amount: Double) -> Degradation {
        pass(leverPreset, mix: amount)
    }

    /// A named machine at a mix (0…1), as chain settings: the preset exactly — its seed included —
    /// with only the mix moved. The lever is this with the lever preset; the Director's
    /// `degrade_part` is this with whichever machine it names.
    static func settings(_ preset: DegradeSettings.Preset, mix: Double) -> DegradeSettings {
        var settings = DegradeSettings(preset: preset)
        settings.mix = min(1, max(0, mix))
        return settings
    }

    /// A named machine at a mix, as a stored pass that remembers which machine it was.
    static func pass(_ preset: DegradeSettings.Preset, mix: Double) -> Degradation {
        settings(preset, mix: mix).degradation(from: preset)
    }

    // MARK: Writing a dusty version

    /// A dirtied part: a new version of the **same** part — `bound` as its parent,
    /// `Operation.degrade` as the operation — playing through `passes`. `bound` is not touched, so
    /// whatever it was still plays as it did. Nil for a kind that cannot carry a chain.
    ///
    /// The one construction of a dusty version. The Sound surface's commit and the Director's
    /// `degrade_part` both come through here, so a chop dirtied by hand and one dirtied by the band
    /// are the same shape in the ledger — same parent edge, same operation, same note — and differ
    /// only in who signed them.
    ///
    /// The note keeps the part's own name ahead of the em dash, which is where `PartLabel` stops
    /// reading: the ledger row still says "Bar 2 of Arrival", and its second line says the chain.
    static func version(dirtying bound: PartVersion, through passes: [Degradation],
                        by author: Author, note: String? = nil) -> PartVersion? {
        guard let kind = bound.kind.withDegradation(passes) else { return nil }
        let chain = passes.isEmpty ? "chain off" : describe(passes)
        return bound.deriving(kind, by: author, operation: Operation.degrade,
                              note: note ?? "\(PartLabel.title(of: bound)) — \(chain)")
    }

    /// The passes a part plays through. Empty for a dry part and for kinds that carry no chain.
    static func passes(of version: PartVersion) -> [Degradation] { version.kind.degradation }

    /// Planar audio through `passes`. Returns the input untouched when there is nothing to do, so a
    /// dry part is bit-identical to its source — which is what makes the Sound surface's `Dry` a
    /// true bypass rather than the chain set to clean.
    static func render(_ planar: [[Float]], sampleRate: Double, passes: [Degradation]) throws -> [[Float]] {
        try DegradeChain.rendered(planar: planar, sampleRate: sampleRate, passes: passes)
    }

    /// "sp1200", "sp1200 over mpc60": the chain as the ledger and the rail say it.
    static func describe(_ passes: [Degradation]) -> String {
        guard !passes.isEmpty else { return "dry" }
        return passes.reversed().map(\.name).joined(separator: " over ")
    }

    /// "SP-1200 at 60%", "Cassette at 100% over SP-1200 at 60%": the chain as a person says it —
    /// the machine's own name and the amount, never a bit depth. What the lineage crumbs show.
    static func spoken(_ passes: [Degradation]) -> String {
        guard !passes.isEmpty else { return "Clean" }
        return passes.reversed().map { pass in
            let mix = pass.parameters[DegradeSettings.PassKey.mix] ?? 1
            return "\(machineName(pass.name)) at \(Int((mix * 100).rounded()))%"
        }.joined(separator: " over ")
    }

    /// The machine's name as printed on it, for the five the instrument models.
    static func machineName(_ preset: String) -> String {
        switch preset.lowercased() {
        case "sp1200": return "SP-1200"
        case "mpc60": return "MPC60"
        case "cassette": return "Cassette"
        case "vinyl": return "Vinyl"
        case "radio": return "Radio"
        default: return preset
        }
    }

    // MARK: The critics

    /// A chain review of a dirtied part: the top pass is `degrade`, the passes beneath it are prior.
    ///
    /// A `ChopReview` wants a `Chop`, and a stored `.sample` carries markers rather than one; the
    /// chain check reads none of the slice fields, so the review is built over an empty chop and the
    /// slice critics — which have nothing to say about a chain — correctly say nothing.
    static func review(label: String, passes: [Degradation], duration: Double = 0,
                       sampleRate: Double = 0, bandwidthHz: Double? = nil) -> ChopReview {
        let top = passes.last.map(DegradeSettings.init)
        let prior = passes.dropLast().map(\.name)
        let chop = Chop(slices: [], sampleRate: sampleRate,
                        sourceFrameCount: Int((duration * sampleRate).rounded()))
        let observation = SourceObservation(label: label, sampleRate: sampleRate, duration: duration,
                                            sliceCount: 0, bandwidthHz: bandwidthHz,
                                            degrade: top, priorDegrades: Array(prior))
        return ChopReview(label: label, chop: chop, degrade: top, observation: observation)
    }

    /// What the chain critic says about a version's own chain. Empty for a dry part.
    static func findings(for version: PartVersion, label: String? = nil,
                         bandwidthHz: Double? = nil) -> [Finding] {
        let passes = passes(of: version)
        guard !passes.isEmpty else { return [] }
        let review = review(label: label ?? PartLabel.title(of: version), passes: passes,
                            bandwidthHz: bandwidthHz)
        return DegradeStackCritic().review(review)
    }

    // MARK: A groove as audio

    /// One pass of a groove as hits, the way `GroovePlayer` lays it down: default options, one
    /// iteration per `repeats`.
    static func hits(for groove: Groove, tempo: Double, timeSignature: TimeSignature,
                     repeats: Int = 1) -> [VoiceSampler.Hit] {
        let timeline = GrooveTimeline.tempo(max(20, tempo), timeSignature: timeSignature)
        return GrooveRenderer.render(groove, on: timeline, options: GrooveRenderOptions(repeats: repeats))
    }

    /// Length of one pass of a groove at this tempo, in seconds.
    static func duration(of groove: Groove, tempo: Double, timeSignature: TimeSignature) -> Double {
        GrooveRenderer.duration(of: groove, on: GrooveTimeline.tempo(max(20, tempo), timeSignature: timeSignature))
    }

    /// How long a drum voice rings past its last hit, for a bounce that should not cut the tail. The
    /// longest factory decay any machine here ships is the 808's long kick, a little under two
    /// seconds.
    static let tail: Double = 2
}
