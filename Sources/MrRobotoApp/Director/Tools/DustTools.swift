import Foundation
import Instrument
import Performance
import SongGraph

// Dirt, as a sound job the band can finish.
//
// The live run asked for "slower and dustier", did the slower half, and handed the dusty half back
// with a sentence that was right about the instrument and wrong about the band: "Dirt is a sound
// job, not an arrangement job." It was right that dust does not belong in `create_part_version` — a
// chain is not an arrangement, and a groove handle cannot say "through an SP-1200". It was wrong
// that the band therefore cannot do it. Dust is carried on the part it dirties (`Degradation`), the
// Sound surface already writes it there, and this is the same write with the band's hand on it.

// MARK: - degrade_part

/// Writes a named machine's chain onto a chop or a groove, as a new `degrade` version of that part.
///
/// ## Why a new tool rather than a wider `create_part_version`
///
/// Two constraints from earlier work decide it, and both point the same way:
///
/// * **The cached prefix.** The tool list renders at position 0 of every request. Appending a tool
///   leaves every schema before it byte-identical; changing `create_part_version`'s schema changes
///   the fourteenth tool's bytes, and `DirectorDustToolboxTests` asserts that it has not.
/// * **The API's schema limits.** The toolbox runs with `strict: false` because the API refused
///   the compiled grammar, and it caps optional parameters across the request at 24 and union-typed
///   ones at 16 (`DirectorToolboxTests` quotes the refusals). Folding dust into
///   `create_part_version` would have added two or three *optional* parameters to a tool whose
///   other callers must leave them out. As its own tool, every parameter is required and plain —
///   zero optional, zero unions — so the budget does not move.
///
/// And the shapes differ: `create_part_version` records a workbench handle as a *new part*
/// spawned from its parent; this writes a new version of the *same part*, from a version id, and
/// nothing on the workbench is involved.
///
/// ## Vocabulary, not DSP
///
/// The model says a machine and an amount — `sp1200` at 0.6 — never a bit depth or a corner. The
/// pass is `Dust.pass(_:mix:)`: the preset exactly, its seed included, with only the mix moved. The
/// seed is never in the model's hands; it comes from the preset and survives as the `UInt64` the
/// graph stores.
///
/// ## Stacking, and the critics
///
/// The new pass goes **on top of** whatever the named version already plays through. Naming a dry
/// version is the ordinary case: the dusty one is its child, and the dry one is one parent back.
/// Naming a dusty one stacks a second machine over the first, which is expressible on purpose —
/// tape over a sampler is a real thing — and is exactly what `DegradeStackCritic` reads.
///
/// Every candidate goes through the chain critic before it is written, over the source's own
/// measured rolloff when the audio is reachable:
///
/// * a **warn** (a second quantiser over a prior one) is refused: nothing is written, and the
///   finding's own sentence is the failure's reason — which is the path every other refusal takes
///   to the rail, so the user reads *why* and not only that `degrade_part` failed. The suggestion
///   translates the critic's two fixes into this tool's own arguments.
/// * a **note** (a corner above the source's rolloff) is written — "the record is full of deliberate
///   versions of this" — and the finding rides on the result for the model and goes on the rail
///   with its reason for the user.
public struct DegradePartTool: DirectorTool {

    public struct Input: Decodable, Sendable {
        public var version: String
        public var preset: String
        public var mix: Double
    }

    public struct Output: Encodable, Sendable {
        /// The dusty version this wrote.
        public var version: String
        /// The version named, which is this one's parent.
        public var parent: String
        /// The nearest version up the line with no chain on it: what the Sound surface's bypass plays.
        public var dry: String
        public var part: String
        public var type: String
        public var operation: String
        public var author: String
        /// "sp1200 at 60%", or "cassette at 40% over sp1200 at 60%".
        public var chain: String
        public var note: String
        public var recorded: Bool
        /// What the chain check said and let through, each with its reason.
        public var findings: [String]
        public var detail: String?
    }

    let workbench: DirectorWorkbench
    let workspace: any DirectorWorkspace
    /// Who signs the version. Kept out of the schema for the reason `CreatePartVersionTool.acting`
    /// is: the frozen prefix must not vary with who is holding the tool.
    let acting: String

    public init(workbench: DirectorWorkbench, workspace: any DirectorWorkspace,
                acting: String = CreatePartVersionTool.director) {
        self.workbench = workbench
        self.workspace = workspace
        self.acting = acting
    }

    /// The machines the model may name. `clean` is not one of them: a dry part is its parent.
    public static let presets: [DegradeSettings.Preset] = [.sp1200, .mpc60, .cassette, .vinyl, .radio]

    public let name = "degrade_part"
    public var purpose: String {
        "Make a chop or a groove dustier by writing a new version of that same part that plays "
        + "through a named machine at a mix. Nothing is printed: the version you name becomes the "
        + "parent and still plays clean. Name a dry version to dirty it; naming a dusty one stacks a "
        + "second machine over the first, and the chain check refuses a second quantiser."
    }
    public var schema: DirectorJSON {
        Schema.object([
            ("version", Schema.string(
                "The sample (chop) or groove version to dirty, by id from read_song or "
                + "create_part_version. To change a dusty version's chain, name its dry parent.")),
            ("preset", Schema.string(
                "Which machine. sp1200: 12-bit, 26 kHz, dark and gritty. mpc60: companded 12-bit, "
                + "40 kHz, thick and punchy. cassette: wow, tape saturation, hiss, a dull top. vinyl: "
                + "record wow, surface noise, crackle. radio: squashed, 4.5 kHz, static.",
                enum: DegradePartTool.presets.map(\.rawValue))),
            ("mix", Schema.number(
                "How much of the machine against the dry part, above 0: 0.6 is \"at 60%\", 1 is the "
                + "machine alone.", maximum: 1)),
        ], required: ["version", "preset", "mix"])
    }

    public func run(_ input: Input) async throws -> Output {
        let bound = try await resolve(input.version)
        guard bound.kind.canCarryDegradation else {
            throw DirectorToolFailure(
                tool: name,
                reason: "A \(bound.type.rawValue) carries no chain: dust lives on a chop or a groove.",
                suggestion: "Name a sample or groove version from read_song or create_part_version.")
        }
        let preset = try machine(input.preset)
        guard input.mix.isFinite, input.mix > 0, input.mix <= 1 else {
            throw DirectorToolFailure(
                tool: name,
                reason: "A mix of \(Schema.figure(input.mix)) is not an amount of a machine.",
                suggestion: "Pass a fraction above 0 and at most 1: 0.6 is \"at 60%\". The dry "
                    + "version needs no call; it already plays clean.")
        }

        let author: Author = .persona(acting)
        let passes = bound.kind.degradation + [Dust.pass(preset, mix: input.mix)]
        guard let version = Dust.version(dirtying: bound, through: passes, by: author) else {
            throw DirectorToolFailure(tool: name, reason: "This \(bound.type.rawValue) cannot carry a chain.")
        }
        let dry = await dryAncestor(of: bound)

        // The chain check, before anything is written.
        let bandwidth = await sourceBandwidth(of: bound)
        let findings = Dust.findings(for: version, bandwidthHz: bandwidth)
        if let refusal = findings.first(where: { $0.severity == .warn }) {
            throw DirectorToolFailure(tool: name,
                                      reason: DegradePartTool.reason(refusal),
                                      suggestion: "Nothing was written. "
                                          + DegradePartTool.fixes(refusal, named: bound, dry: dry))
        }

        let recorded = await workspace.record(version)
        let chain = DegradePartTool.describe(passes)
        let note = version.note ?? chain
        // The version's own ledger line is written by the record itself; what the rail needs from
        // here is what the chain check said, with its reason.
        if recorded {
            for finding in findings {
                await workspace.note("\(finding.criticName): \(finding.headline)",
                                     detail: "\(finding.why) \(finding.measurement.description)")
            }
        }
        return Output(version: version.id.description,
                      parent: bound.id.description,
                      dry: dry.id.description,
                      part: version.partID.description,
                      type: version.type.rawValue,
                      operation: Operation.degrade,
                      author: author.description,
                      chain: chain,
                      note: note,
                      recorded: recorded,
                      findings: findings.map {
                          DegradePartTool.reason($0) + " "
                              + DegradePartTool.fixes($0, named: bound, dry: dry)
                      },
                      detail: recorded
                          ? "Open the Sound surface on \(version.id.description) to put it against "
                              + "the dry version; its chain is already on it, so it needs no dust lever."
                          : "No song is open, so this was not recorded anywhere.")
    }

    // MARK: Reading the arguments

    private func resolve(_ id: String) async throws -> PartVersion {
        guard let versionID = VersionID(uuidString: id) else {
            throw DirectorToolFailure(tool: name, reason: "\"\(id)\" is not a version id.",
                                      suggestion: "Take one from read_song or create_part_version.")
        }
        guard let found = await workspace.version(versionID) else {
            throw DirectorToolFailure(tool: name, reason: "This song has no version \(id).",
                                      suggestion: "Call read_song to see what it has.")
        }
        return found
    }

    /// The machine by the name the model wrote. "SP-1200" and "sp 1200" are the same machine as
    /// `sp1200`: that is reading, not correcting — the name has one referent either way.
    private func machine(_ raw: String) throws -> DegradeSettings.Preset {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        guard let preset = DegradePartTool.presets.first(where: { $0.rawValue == key }) else {
            throw DirectorToolFailure(
                tool: name,
                reason: "\"\(raw)\" is not a machine this instrument has.",
                suggestion: "One of: \(DegradePartTool.presets.map(\.rawValue).joined(separator: ", ")).")
        }
        return preset
    }

    /// The nearest version up the first-parent line whose part plays dry. The version itself when
    /// it is dry; itself again when the line leaves the song, which is the honest answer then.
    private func dryAncestor(of version: PartVersion) async -> PartVersion {
        var current = version
        var seen: Set<VersionID> = [current.id]
        while !current.kind.degradation.isEmpty,
              let parentID = current.parents.first, seen.insert(parentID).inserted,
              let parent = await workspace.version(parentID), parent.partID == current.partID {
            current = parent
        }
        return current
    }

    // MARK: The source's own top end

    /// The chop's 95% rolloff over the region it covers, when its audio can be reached: from the
    /// workbench when this session imported it, from the library otherwise. A groove playing a
    /// chop's slices is measured by that chop, which is its sound. Nil for a groove on a machine —
    /// whose sound is a machine bounce, not a source — and whenever the audio is not reachable, in
    /// which case the corner check has nothing to measure against and correctly says nothing.
    private func sourceBandwidth(of version: PartVersion) async -> Double? {
        let song = await workspace.song
        var source = version
        if case .groove = version.kind, let song,
           let chop = ChopSound.part(of: SongPlayback.drumSoundID(for: version.partID, in: song)),
           let cut = song.versions.last(where: { $0.partID == chop }) {
            source = cut
        }
        guard case .sample(let sample) = source.kind else { return nil }
        let region = ChopLaneBinding.region(of: sample,
                                            bars: Guidance.analysis(in: song)?.bars ?? [],
                                            tempo: sample.detectedTempo ?? song?.tempo)
        for handle in await workbench.audioHandles {
            guard let audio = try? await workbench.audio(handle), audio.media == sample.media else { continue }
            let from = max(0, min(audio.frameCount, Int((region.start * audio.sampleRate).rounded())))
            let to = max(from, min(audio.frameCount, Int((region.end * audio.sampleRate).rounded())))
            guard to > from else { return nil }
            return SourceMeasurement.rolloff(Array(audio.mono[from..<to]), sampleRate: audio.sampleRate)
        }
        guard let store = await workspace.store,
              let url = try? store.mediaURL(for: sample.media, song: song?.id),
              let span = try? AudioRegion.read(url, from: region.start, to: region.end),
              !(span.planar.first?.isEmpty ?? true) else { return nil }
        return SourceMeasurement.rolloff(ChopAudio.mono(span.planar), sampleRate: span.sampleRate)
    }

    // MARK: Saying it

    /// "sp1200 at 60%", passes nearest the listener first, the way `Dust.describe` orders them.
    static func describe(_ passes: [Degradation]) -> String {
        guard !passes.isEmpty else { return "dry" }
        return passes.reversed().map { pass in
            let mix = pass.parameters[DegradeSettings.PassKey.mix] ?? 1
            return "\(pass.name) at \(Int((mix * 100).rounded()))%"
        }.joined(separator: " over ")
    }

    /// A finding as the reason for a refusal: the check's name, then *why*, then the headline with
    /// the numbers it measured.
    ///
    /// The why goes first because the rail keeps a failure's first sentence and cuts the rest
    /// (`DirectorSession.refusals`), and the first sentence must be the reason rather than the name.
    static func reason(_ finding: Finding) -> String {
        "\(finding.criticName): \(finding.why) (\(finding.headline).)"
    }

    /// The critic's two fixes, said as this tool's own arguments so the model can take one.
    ///
    /// "Take the chain off" means different things over a dry version and a dusty one: over a dry
    /// one it is "leave it dry"; over a dusty one it is "keep what it already is", and the other
    /// honest option is the dry version with this machine on it instead of on top.
    static func fixes(_ finding: Finding, named bound: PartVersion, dry: PartVersion) -> String {
        finding.fixes.enumerated().map { index, fix -> String in
            // "Or take the chain off", not "Or Take": the second offer reads as the same sentence.
            let title = index == 0 ? fix.title : fix.title.prefix(1).lowercased() + fix.title.dropFirst()
            switch fix.change {
            case .setDegradePreset(nil):
                guard bound.id != dry.id else {
                    return "\(title): leave \(dry.id.description) dry."
                }
                return "\(title): keep \(bound.id.description) as it is, or name its dry version "
                    + "\(dry.id.description) to put this machine on instead of on top."
            case .setDegradePreset(let other?):
                return "\(title): the same call with preset \(other)."
            case .setDegradeMix(let amount):
                return "\(title): the same call with mix \(Schema.figure((amount * 100).rounded() / 100))."
            default:
                return "\(title)."
            }
        }.joined(separator: " Or ")
    }
}
