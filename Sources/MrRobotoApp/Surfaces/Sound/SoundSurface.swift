import AVFoundation
import Foundation
import Instrument
import Observation
import SongGraph

/// Which panel is in front. The surface is one thing at a time on purpose: the question is either
/// "what is this drum" or "how dusty is it", and asking both at once is the mixer strip the M1 spec
/// says not to build.
public enum SoundPanel: String, Hashable, Sendable, CaseIterable {
    case voice, chain

    public var title: String {
        switch self {
        case .voice: "Voice"
        case .chain: "Chain"
        }
    }
}

/// Which side of the A/B you are hearing.
public enum SoundMonitor: String, Hashable, Sendable, CaseIterable {
    /// Through the degradation chain.
    case chain
    /// True bypass: the synthesizer's own samples, untouched.
    case dry
}

/// The Sound surface: four to six controls for the voice or the chain in front of you, every one of
/// which makes a sound the moment you move it.
///
/// ## The four rules
///
/// * **Binds to parts.** It opens against the host's selected part version and reads `SoundState`
///   out of it. The only state of its own is a *draft* of the edit in progress plus which panel and
///   which side of the A/B you are on — the things a reopen is allowed to forget.
/// * **Plays on touch.** `setValue` re-renders that one voice and auditions it. `DrumSynthesizer`
///   is a pure generator, so this is a few milliseconds of arithmetic and no engine round trip. It
///   never calls `SynthesizedKit.rerender`: re-rendering twelve voices at three velocity layers to
///   hear one knob would be absurd. Catching the kit folder up is the host's job, once, on commit.
/// * **Two speeds.** Everything here is local. The agent is not involved in turning a knob.
/// * **Flags, never fixes.** Nothing is corrected silently; a control that the machine does not
///   have simply is not shown, and one whose name lies about its wiring says so.
///
/// ## The A/B
///
/// `monitor` switches between the chain and true bypass. Bypass means the synthesizer's samples,
/// not the chain set to `.clean` — `rendered(.dry)` is bit-identical to `DrumSynthesizer.render`.
/// That matters because the degradation research's own finding was that an unmatched A/B is a
/// loudness contest: `CDegrade` normalises every saturation curve by its slope at the origin, so
/// `|y| <= |x|` at any drive and the chain can only compress. A true bypass is what makes that
/// audible rather than merely documented.
@MainActor
@Observable
public final class SoundSurface {

    // MARK: Identity

    public nonisolated let id: SurfaceID

    /// A value the frame can put in its bench and hold across isolation domains.
    public var binding: SoundSurfaceBinding {
        SoundSurfaceBinding(id: id, bound: boundVersion.map { [$0.id] } ?? [], title: title)
    }

    /// `"TR-808 kick"`, or `"TR-808 kick · vinyl"` once the chain is doing something.
    public var title: String {
        guard !draft.degrade.isBypass else { return draft.label }
        let chain = draft.degrade.matchingPreset?.rawValue ?? "chain"
        return "\(draft.label) · \(chain)"
    }

    // MARK: Host

    private weak var host: (any SoundSurfaceHost)?

    /// Render rate. The sampler's rate, so a commit does not resample what you auditioned.
    public let sampleRate: Double

    /// The velocity an audition is played at. One value, because an audition is a check on the
    /// voice, not a performance.
    public let auditionVelocity: Int

    // MARK: State

    /// The edit in progress. Seeded from the bound version and written back by `commit`; it is a
    /// draft, not state the surface owns, which is why `isDirty` is visible and `revert` exists.
    public private(set) var draft: SoundState

    /// The state as the bound version has it.
    public private(set) var committed: SoundState

    /// The version this surface opened against, if there was one.
    public private(set) var boundVersion: PartVersion?

    public var panel: SoundPanel = .voice

    /// Which side of the A/B. Setting it re-auditions, because that is the whole point of a
    /// comparison: one gesture, the same hit, the other side.
    public var monitor: SoundMonitor = .chain {
        didSet { if monitor != oldValue { audition() } }
    }

    /// The chain panel shows its two prominent levers and the presets; the remaining seven are
    /// behind this. A chain is nine parameters and a surface is four to six controls, so the rest
    /// of it is available rather than present.
    public var showsFullChain = false

    /// Set when a render could not be put through the chain — `DegradeChain` refused the rate or
    /// could not allocate. The dry signal is auditioned instead; nothing is corrected silently.
    public private(set) var chainFailure: String?

    public var isDirty: Bool { draft != committed }

    // MARK: Init

    public init(id: SurfaceID = SurfaceID(),
                host: any SoundSurfaceHost,
                sampleRate: Double = 48_000,
                auditionVelocity: Int = 100) {
        self.id = id
        self.host = host
        self.sampleRate = sampleRate
        self.auditionVelocity = auditionVelocity
        let state = host.selectedPart.flatMap(SoundState.init) ?? SoundState()
        self.draft = state
        self.committed = state
        self.boundVersion = host.selectedPart
    }

    /// Re-reads the host's selection, discarding any draft. The frame calls this when the selection
    /// changes under the surface.
    public func reload() {
        let version = host?.selectedPart
        let state = version.flatMap(SoundState.init) ?? SoundState()
        boundVersion = version
        draft = state
        committed = state
        chainFailure = nil
    }

    // MARK: Controls

    /// The controls for the panel in front of you.
    public var controls: [SoundControl] { controls(for: panel) }

    public func controls(for panel: SoundPanel) -> [SoundControl] {
        switch panel {
        case .voice: SoundControl.voiceControls(for: draft.spec)
        case .chain: SoundControl.chainControls(for: draft.degrade)
        }
    }

    /// At most two. The M1 spec's rule, and the reason this is a surface and not a mixer strip.
    public var prominentControls: [SoundControl] { controls.filter(\.isProminent) }

    public var quietControls: [SoundControl] { controls.filter { !$0.isProminent } }

    /// Moves a control, re-renders that one voice, and plays it.
    ///
    /// Called from a slider's `onChange`, so it runs at gesture rate. That is affordable: a 1.6 s
    /// 808 kick at 48 kHz is about 77 000 samples of straight-line arithmetic.
    public func setValue(_ value: Double, for parameter: SoundControl.Parameter) {
        guard let control = controls(for: panel(of: parameter))
            .first(where: { $0.parameter == parameter }) else { return }
        let clamped = min(max(value, control.range.lowerBound), control.range.upperBound)
        guard apply(clamped, to: parameter) else { return }
        audition()
    }

    /// Applies a named parameter set to the chain and plays the result. The presets are read out of
    /// the C, so "sp1200" here means exactly what it means everywhere else.
    public func apply(_ preset: DegradeSettings.Preset) {
        draft.degrade = DegradeSettings(preset: preset)
        draft.chainBase = preset
        chainFailure = nil
        audition()
    }

    /// Switches voice within the same machine. The chain is unchanged — it is a chain, not part of
    /// the voice — and the new voice's own knob positions come from the machine preset.
    public func select(_ voice: SynthVoiceKind) {
        guard voice != draft.voice, draft.availableVoices.contains(voice) else { return }
        draft.voice = voice
        draft.controls = SoundState.factorySpec(machine: draft.machine, voice: voice).controls
        panel = .voice
        audition()
    }

    /// Puts one control back where the machine preset had it.
    public func reset(_ parameter: SoundControl.Parameter) {
        switch parameter {
        case .machine(let knob):
            let factory = draft.factorySpec.controls
            _ = apply(value(of: knob, in: factory), to: parameter)
        case .chain:
            let base = DegradeSettings(preset: draft.chainBase)
            _ = apply(chainValue(of: parameter, in: base) ?? 0, to: parameter)
        }
        audition()
    }

    /// Drops the draft and goes back to what the bound version says.
    public func revert() {
        draft = committed
        chainFailure = nil
    }

    // MARK: Rendering and audition

    /// Renders the current draft. Pure: the same draft and the same monitor always give the same
    /// samples, which is what makes an A/B a comparison rather than a coin toss.
    ///
    /// `.dry` is a true bypass — the synthesizer's own output, not the chain set to clean.
    public func rendered(_ monitor: SoundMonitor) -> [Float] {
        let dry = DrumSynthesizer.render(draft.spec, velocity: auditionVelocity, sampleRate: sampleRate)
        guard monitor == .chain, !draft.degrade.isBypass else { return dry }
        do {
            return try Self.throughChain(dry, settings: draft.degrade, sampleRate: sampleRate)
        } catch {
            return dry
        }
    }

    /// Renders the current draft on the current side of the A/B and hands it to the host.
    public func audition() {
        let dry = DrumSynthesizer.render(draft.spec, velocity: auditionVelocity, sampleRate: sampleRate)
        var samples = dry
        var isDry = true
        if monitor == .chain, !draft.degrade.isBypass {
            do {
                samples = try Self.throughChain(dry, settings: draft.degrade, sampleRate: sampleRate)
                isDry = false
                chainFailure = nil
            } catch {
                chainFailure = "\(error)"
            }
        } else {
            chainFailure = nil
        }
        host?.audition(SoundAudition(samples: samples, sampleRate: sampleRate,
                                     label: draft.label, isDry: isDry))
    }

    /// One offline pass through a fresh chain, latency-compensated, so sample *n* out is sample *n*
    /// in and the A/B does not slip by the wow delay line.
    static func throughChain(_ samples: [Float], settings: DegradeSettings,
                             sampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let input = source.floatChannelData else {
            throw DegradeChain.Failure.couldNotCreate(sampleRate: sampleRate, channelCount: 1)
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input[0].update(from: $0.baseAddress!, count: samples.count) }

        let processed = try DegradeChain.rendered(source, settings: settings)
        guard let output = processed.floatChannelData else { return samples }
        return Array(UnsafeBufferPointer(start: output[0], count: Int(processed.frameLength)))
    }

    // MARK: Commit

    /// Writes the draft back as a **new** part version and hands it to the host.
    ///
    /// Never mutates the version it opened against: an edit derives from it, keeping the same part
    /// and naming it as a parent. With nothing selected, this starts a part instead.
    ///
    /// - Returns: the version written, or `nil` when nothing moved or the host refused it.
    @discardableResult
    public func commit(note: String? = nil) -> PartVersion? {
        guard isDirty else { return nil }
        let kind = PartKind.sound(draft.sound)
        let version = boundVersion?.deriving(kind, by: .user, operation: Operation.edit, note: note)
            ?? PartVersion(partID: PartID(), kind: kind, author: .user,
                           operation: Operation.written, note: note)
        guard host?.record(version) == true else { return nil }
        boundVersion = version
        committed = draft
        return version
    }

    // MARK: Applying a value

    private func panel(of parameter: SoundControl.Parameter) -> SoundPanel {
        if case .machine = parameter { return .voice }
        return .chain
    }

    /// - Returns: whether anything actually moved, so an audition is not fired for a no-op.
    private func apply(_ value: Double, to parameter: SoundControl.Parameter) -> Bool {
        let before = draft
        switch parameter {
        case .machine(let knob):
            switch knob {
            case .tune: draft.controls.tune = value
            case .decay: draft.controls.decay = value
            case .tone: draft.controls.tone = value
            case .snappy: draft.controls.snappy = value
            case .attack: draft.controls.attack = value
            case .level: draft.controls.level = value
            }
        case .chain(let knob):
            switch knob {
            case .bitDepth: draft.degrade.bitDepth = value
            case .sampleRate: draft.degrade.targetSampleRate = value
            case .drive:
                draft.degrade.drive = value
                // DRIVE with `saturation == .none` is a plain linear gain, and the A/B's whole
                // claim is that the chain never adds level. This surface does not offer a curve
                // control — the curve belongs to the preset — so pushing drive up on a chain that
                // has no curve gives it the soft clip to drive into, and backing off restores the
                // preset's own curve. Not silent: the DRIVE readout names the curve it is using.
                let curve = DegradeSettings(preset: draft.chainBase).saturation
                draft.degrade.saturation = value > 1 && curve == .none ? .soft : curve
            case .wow: draft.degrade.wowDepth = value
            case .flutter: draft.degrade.flutterDepth = value
            case .noise: draft.degrade.noiseLevel = value
            case .crackle: draft.degrade.crackleDensity = value
            case .highCut: draft.degrade.highCut = value
            case .mix: draft.degrade.mix = value
            }
        }
        return draft != before
    }

    private func value(of knob: SoundControl.MachineControl, in controls: SynthControls) -> Double {
        switch knob {
        case .tune: controls.tune
        case .decay: controls.decay
        case .tone: controls.tone
        case .snappy: controls.snappy
        case .attack: controls.attack
        case .level: controls.level
        }
    }

    private func chainValue(of parameter: SoundControl.Parameter,
                            in settings: DegradeSettings) -> Double? {
        guard case .chain(let knob) = parameter else { return nil }
        switch knob {
        case .bitDepth: return settings.bitDepth
        case .sampleRate: return settings.targetSampleRate
        case .drive: return settings.drive
        case .wow: return settings.wowDepth
        case .flutter: return settings.flutterDepth
        case .noise: return settings.noiseLevel
        case .crackle: return settings.crackleDensity
        case .highCut: return settings.highCut
        case .mix: return settings.mix
        }
    }
}

/// The catalog entry for an open Sound surface.
///
/// `Surface` is a `Sendable` value contract and `SoundSurface` is a `@MainActor` observable model,
/// so the conformance lives here rather than on the model: the frame holds one of these in its
/// bench, and the model is what the view talks to.
public struct SoundSurfaceBinding: Surface {
    public let id: SurfaceID
    public static var kind: SurfaceKind { .sound }
    public let bound: [VersionID]
    public let title: String

    public init(id: SurfaceID, bound: [VersionID], title: String) {
        self.id = id
        self.bound = bound
        self.title = title
    }
}
