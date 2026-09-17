import Foundation
import Instrument
import SongGraph

/// Everything the Sound surface is looking at, as a value: which voice of which machine, where its
/// six knobs are, and what the degradation chain is set to.
///
/// It is a value on purpose. The surface holds one of these as the *draft* of an uncommitted edit
/// and one as the version it opened against; `isDirty` is `!=` between them and a commit is
/// `PartVersion.deriving(.sound(draft.sound), …)`. Nothing here is ever mutated in place inside a
/// stored version.
///
/// ## What a `Sound` part actually carries
///
/// `SongGraph.Sound` is `instrument: String`, `preset: String?` and `parameters: [String: Double]`.
/// So a Sound part records **the machine, the voice, the six knob positions and the chain's
/// parameters** — not the circuit. The circuit (`SynthTone`, `SynthNoise`, `SynthClick`,
/// `SynthOutput`) comes back from `SynthMachine.preset(id:)`, which is right: a preset sets the
/// internals from the schematic and a person turns the knobs.
public struct SoundState: Equatable, Sendable {

    /// A `SynthMachine.id`: `"tr808"`, `"tr909"`, `"linn"`.
    public var machine: String
    public var voice: SynthVoiceKind
    /// TUNE, DECAY, TONE, SNAPPY, ATTACK, LEVEL as normalised knob positions.
    public var controls: SynthControls
    public var degrade: DegradeSettings

    /// The named parameter set this chain was last reached from.
    ///
    /// It is stored because `DegradeSettings.seed` is a `UInt64` — `0x9E3779B97F4A7C15` for every
    /// non-clean preset — and a `[String: Double]` cannot carry that without losing the low bits.
    /// Rather than round-trip a seed badly, the seed comes from this preset and the surface does not
    /// offer a seed control. Auditioning a different pressing means choosing a preset.
    public var chainBase: DegradeSettings.Preset

    public init(machine: String = SynthMachine.tr808.id,
                voice: SynthVoiceKind = .kick,
                controls: SynthControls? = nil,
                degrade: DegradeSettings = .clean,
                chainBase: DegradeSettings.Preset = .clean) {
        self.machine = machine
        self.voice = voice
        self.controls = controls ?? Self.factorySpec(machine: machine, voice: voice).controls
        self.degrade = degrade
        self.chainBase = chainBase
    }

    // MARK: The voice

    /// The machine's spec for this voice with the draft's knob positions substituted in. This is
    /// what goes to `DrumSynthesizer.render`, and it is the only thing that does.
    public var spec: SynthVoiceSpec {
        var spec = Self.factorySpec(machine: machine, voice: voice)
        spec.controls = controls
        return spec
    }

    /// The untouched machine preset, for "what did the factory have this at".
    public var factorySpec: SynthVoiceSpec { Self.factorySpec(machine: machine, voice: voice) }

    /// The machine, falling back to the 808 rather than failing: a Sound part written against a
    /// machine this build does not have should still open and play something.
    public var synthMachine: SynthMachine { SynthMachine.preset(id: machine) ?? .tr808 }

    /// Voices this machine offers, in the machine's own order.
    public var availableVoices: [SynthVoiceKind] { synthMachine.voices.map(\.kind) }

    static func factorySpec(machine: String, voice: SynthVoiceKind) -> SynthVoiceSpec {
        let machine = SynthMachine.preset(id: machine) ?? .tr808
        return machine.spec(for: voice)
            ?? machine.voices.first
            ?? SynthMachine.tr808.voices[0]
    }

    /// `"TR-808 kick"` — what the surface header says and what an audition is labelled with.
    public var label: String {
        "\(synthMachine.name) \(voice.rawValue)"
    }

    // MARK: - The part payload

    /// Keys in `Sound.parameters`. Machine knobs keep the panel's own lower-cased names; everything
    /// the chain owns is prefixed, so the two never collide.
    enum Key {
        static let tune = "tune", decay = "decay", tone = "tone"
        static let snappy = "snappy", attack = "attack", level = "level"

        static let bitDepth = "chain.bitDepth", companding = "chain.companding"
        static let targetSampleRate = "chain.targetSampleRate", antiAliasing = "chain.antiAliasing"
        static let drive = "chain.drive", saturation = "chain.saturation"
        static let wowDepth = "chain.wowDepth", wowRate = "chain.wowRate"
        static let flutterDepth = "chain.flutterDepth", flutterRate = "chain.flutterRate"
        static let noiseLevel = "chain.noiseLevel", crackleDensity = "chain.crackleDensity"
        static let highCut = "chain.highCut", mix = "chain.mix"
    }

    /// `Sound.instrument` is `"drum.<machine>.<voice>"`, e.g. `"drum.tr808.kick"`.
    static let instrumentPrefix = "drum"

    /// The part payload for this state.
    public var sound: Sound {
        Sound(
            instrument: "\(Self.instrumentPrefix).\(machine).\(voice.rawValue)",
            preset: chainBase.rawValue,
            parameters: [
                Key.tune: controls.tune,
                Key.decay: controls.decay,
                Key.tone: controls.tone,
                Key.snappy: controls.snappy,
                Key.attack: controls.attack,
                Key.level: controls.level,
                Key.bitDepth: degrade.bitDepth,
                Key.companding: degrade.companding,
                Key.targetSampleRate: degrade.targetSampleRate,
                Key.antiAliasing: Double(Self.index(of: degrade.antiAliasing)),
                Key.drive: degrade.drive,
                Key.saturation: Double(Self.index(of: degrade.saturation)),
                Key.wowDepth: degrade.wowDepth,
                Key.wowRate: degrade.wowRate,
                Key.flutterDepth: degrade.flutterDepth,
                Key.flutterRate: degrade.flutterRate,
                Key.noiseLevel: degrade.noiseLevel,
                Key.crackleDensity: degrade.crackleDensity,
                Key.highCut: degrade.highCut,
                Key.mix: degrade.mix,
            ]
        )
    }

    /// Reads a Sound part back. Returns `nil` only when the instrument is not a drum voice this
    /// surface can drive — a `"chain.lofi-tape"` part belongs to a different surface.
    ///
    /// Every parameter is optional: an older part that carried fewer keys opens with the machine
    /// preset's values for the rest, the same tolerance `SynthVoiceSpec` decodes with.
    public init?(_ sound: Sound) {
        let fields = sound.instrument.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == Self.instrumentPrefix,
              let voice = SynthVoiceKind(rawValue: String(fields[2])) else { return nil }
        let machine = String(fields[1])

        let base = sound.preset.flatMap(DegradeSettings.Preset.init(rawValue:)) ?? .clean
        var chain = DegradeSettings(preset: base)
        let p = sound.parameters
        if let v = p[Key.bitDepth] { chain.bitDepth = v }
        if let v = p[Key.companding] { chain.companding = v }
        if let v = p[Key.targetSampleRate] { chain.targetSampleRate = v }
        if let v = p[Key.antiAliasing] { chain.antiAliasing = Self.antiAliasing(at: v) }
        if let v = p[Key.drive] { chain.drive = v }
        if let v = p[Key.saturation] { chain.saturation = Self.saturation(at: v) }
        if let v = p[Key.wowDepth] { chain.wowDepth = v }
        if let v = p[Key.wowRate] { chain.wowRate = v }
        if let v = p[Key.flutterDepth] { chain.flutterDepth = v }
        if let v = p[Key.flutterRate] { chain.flutterRate = v }
        if let v = p[Key.noiseLevel] { chain.noiseLevel = v }
        if let v = p[Key.crackleDensity] { chain.crackleDensity = v }
        if let v = p[Key.highCut] { chain.highCut = v }
        if let v = p[Key.mix] { chain.mix = v }

        var controls = Self.factorySpec(machine: machine, voice: voice).controls
        if let v = p[Key.tune] { controls.tune = v }
        if let v = p[Key.decay] { controls.decay = v }
        if let v = p[Key.tone] { controls.tone = v }
        if let v = p[Key.snappy] { controls.snappy = v }
        if let v = p[Key.attack] { controls.attack = v }
        if let v = p[Key.level] { controls.level = v }

        self.init(machine: machine, voice: voice, controls: controls,
                  degrade: chain, chainBase: base)
    }

    /// Reads the Sound payload out of a part version, if that is what it is.
    public init?(_ version: PartVersion) {
        guard case .sound(let sound) = version.kind else { return nil }
        self.init(sound)
    }

    // MARK: Enum <-> number

    // `parameters` is `[String: Double]`, so the two enumerations travel as their index in
    // `allCases`. Both are small integers and exact in a Double; the seed is the one field that is
    // not, and it is handled by `chainBase` instead.

    private static func index(of value: DegradeSettings.AntiAliasing) -> Int {
        DegradeSettings.AntiAliasing.allCases.firstIndex(of: value) ?? 0
    }

    private static func index(of value: DegradeSettings.Saturation) -> Int {
        DegradeSettings.Saturation.allCases.firstIndex(of: value) ?? 0
    }

    private static func antiAliasing(at value: Double) -> DegradeSettings.AntiAliasing {
        let all = DegradeSettings.AntiAliasing.allCases
        let i = Int(value.rounded())
        return all.indices.contains(i) ? all[i] : .filtered
    }

    private static func saturation(at value: Double) -> DegradeSettings.Saturation {
        let all = DegradeSettings.Saturation.allCases
        let i = Int(value.rounded())
        return all.indices.contains(i) ? all[i] : .none
    }
}
