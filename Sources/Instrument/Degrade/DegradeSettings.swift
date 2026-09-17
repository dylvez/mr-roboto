import CDegrade
import Foundation

/// The degradation chain's parameters as a value type: `Codable` so a part version can carry the
/// exact chain a bounce was made with, `Equatable` so a UI can tell whether anything moved, and
/// `Sendable` so it can be handed across isolation boundaries without ceremony.
///
/// The C header (`CDegrade.h`) is where the machines behind these numbers are documented — the
/// SP-1200's 26.04 kHz and 12 linear bits, the MPC60's 40 kHz and companded 12, the wow and flutter
/// percentages real decks are specified in, and the sources for all of it. This file is the typed
/// surface over that, and deliberately holds no opinions the C does not.
///
/// Decoding is tolerant: every field falls back to its clean-preset value when absent, so a stored
/// settings blob written before a field existed still loads. Encoding always writes every field.
public struct DegradeSettings: Codable, Sendable, Equatable {

    /// The saturation curve. See `dg_sat` for the shapes; all of them are monotonic and finite at
    /// any drive.
    public enum Saturation: String, Codable, Sendable, CaseIterable {
        /// No curve — `drive` is a plain linear gain.
        case none
        /// Symmetric soft clip, odd harmonics only.
        case soft
        /// Soft clip with a 15% asymmetry, for the small even-order content tape's bias adds to its
        /// otherwise symmetric hysteresis loop.
        case tape
        /// The same shape at 60% asymmetry, for a single-ended valve stage.
        case tube
        /// Hard clip at unity after drive.
        case hard

        var raw: Int32 {
            switch self {
            case .none: Int32(DG_SAT_NONE.rawValue)
            case .soft: Int32(DG_SAT_SOFT.rawValue)
            case .tape: Int32(DG_SAT_TAPE.rawValue)
            case .tube: Int32(DG_SAT_TUBE.rawValue)
            case .hard: Int32(DG_SAT_HARD.rawValue)
            }
        }

        init(raw: Int32) {
            switch UInt32(max(0, raw)) {
            case DG_SAT_SOFT.rawValue: self = .soft
            case DG_SAT_TAPE.rawValue: self = .tape
            case DG_SAT_TUBE.rawValue: self = .tube
            case DG_SAT_HARD.rawValue: self = .hard
            default: self = .none
            }
        }
    }

    /// Whether the sample-rate reducer filters before it decimates. Both are wanted: `none` folds
    /// everything above the target Nyquist back into the band, which *is* the sound of an SP-1200
    /// chop, and `filtered` removes it first, which is what you reach for when you only want the
    /// bandwidth limit. Neither removes the zero-order hold's upward imaging — that is the missing
    /// reconstruction filter, and it is kept on purpose.
    public enum AntiAliasing: String, Codable, Sendable, CaseIterable {
        case none
        case filtered

        var raw: Int32 {
            self == .filtered ? Int32(DG_AA_FILTERED.rawValue) : Int32(DG_AA_NONE.rawValue)
        }

        init(raw: Int32) {
            self = (UInt32(max(0, raw)) == DG_AA_FILTERED.rawValue) ? .filtered : .none
        }
    }

    /// The named parameter sets. The raw values are the persisted identifiers and match
    /// `dg_preset_name` exactly; do not rename them.
    public enum Preset: String, Codable, Sendable, CaseIterable {
        case clean, sp1200, mpc60, cassette, vinyl, radio
    }

    /// Quantiser width in bits, continuous — 12.0 and 12.5 both mean something. At or above 24 the
    /// stage is off and bit-transparent, which is what `.bitDepthOff` is for.
    public var bitDepth: Double
    /// mu-law companding amount around the quantiser. 0 is linear (the SP-1200); a positive value
    /// makes the quantisation floor follow the signal instead of sitting at a fixed level, which is
    /// how the MPC60's "12-bit non-linear" format behaves.
    public var companding: Double
    /// Rate the decimator holds to, in Hz. 0 disables the stage.
    public var targetSampleRate: Double
    /// Whether the decimator filters before it holds.
    public var antiAliasing: AntiAliasing
    /// Linear gain into the saturation curve; 1 is unity.
    public var drive: Double
    public var saturation: Saturation
    /// Peak pitch deviation as a fraction — 0.001 is the 0.1% a cassette deck is specified in.
    public var wowDepth: Double
    /// Wow oscillator rate in Hz. Below 4 Hz by convention; 0.5556 Hz is one revolution of a 33 1/3
    /// rpm record.
    public var wowRate: Double
    /// Peak pitch deviation of the faster component.
    public var flutterDepth: Double
    /// Flutter oscillator rate in Hz. Above 4 Hz by convention.
    public var flutterRate: Double
    /// Linear amplitude of the medium noise bed: bright hiss plus a low-passed rumble bed.
    public var noiseLevel: Double
    /// Crackle events per second, as the rate of a Poisson process. Amplitude is drawn per event
    /// and is deliberately not scaled by `noiseLevel`.
    public var crackleDensity: Double
    /// Corner of the output rolloff in Hz — two cascaded one-poles, so -6 dB here and -12 dB per
    /// octave above. 0 disables the stage.
    public var highCut: Double
    /// 0 is the untouched input, 1 is the fully processed signal. The dry path is delayed to match,
    /// so a partial mix does not comb.
    public var mix: Double
    /// Seed for the noise and crackle generator. Two renders with the same seed over the same input
    /// are byte-identical — the offline bounce guarantee rests on this.
    public var seed: UInt64

    /// The value of `bitDepth` that means "do not quantise at all".
    public static let bitDepthOff = Double(DG_BITS_OFF)

    public init(bitDepth: Double = DegradeSettings.bitDepthOff,
                companding: Double = 0,
                targetSampleRate: Double = 0,
                antiAliasing: AntiAliasing = .filtered,
                drive: Double = 1,
                saturation: Saturation = .none,
                wowDepth: Double = 0,
                wowRate: Double = 0,
                flutterDepth: Double = 0,
                flutterRate: Double = 0,
                noiseLevel: Double = 0,
                crackleDensity: Double = 0,
                highCut: Double = 0,
                mix: Double = 1,
                seed: UInt64 = 0) {
        self.bitDepth = bitDepth
        self.companding = companding
        self.targetSampleRate = targetSampleRate
        self.antiAliasing = antiAliasing
        self.drive = drive
        self.saturation = saturation
        self.wowDepth = wowDepth
        self.wowRate = wowRate
        self.flutterDepth = flutterDepth
        self.flutterRate = flutterRate
        self.noiseLevel = noiseLevel
        self.crackleDensity = crackleDensity
        self.highCut = highCut
        self.mix = mix
        self.seed = seed
    }

    // MARK: - Presets

    /// The clean set: every stage off. A chain created with this and never given anything else is
    /// bit-transparent, not merely quiet — see `DegradeChain.isBypassed`.
    public static let clean = DegradeSettings(preset: .clean)

    /// A named parameter set, read straight out of the C so there is exactly one definition of
    /// what "sp1200" means.
    public init(preset: Preset) {
        var params = dg_params_t()
        if dg_preset_named(preset.rawValue, &params) != 0 {
            dg_params_default(&params)
        }
        self.init(params)
    }

    /// Non-nil only for a settings value that is exactly one of the named sets, unmodified.
    public var matchingPreset: Preset? {
        Preset.allCases.first { DegradeSettings(preset: $0) == self }
    }

    // MARK: - C bridging

    init(_ p: dg_params_t) {
        self.init(bitDepth: Double(p.bitDepth),
                  companding: Double(p.companding),
                  targetSampleRate: Double(p.targetSampleRate),
                  antiAliasing: AntiAliasing(raw: p.antiAlias),
                  drive: Double(p.drive),
                  saturation: Saturation(raw: p.saturation),
                  wowDepth: Double(p.wowDepth),
                  wowRate: Double(p.wowRate),
                  flutterDepth: Double(p.flutterDepth),
                  flutterRate: Double(p.flutterRate),
                  noiseLevel: Double(p.noiseLevel),
                  crackleDensity: Double(p.crackleDensity),
                  highCut: Double(p.highCut),
                  mix: Double(p.mix),
                  seed: p.seed)
    }

    var cParams: dg_params_t {
        var p = dg_params_t()
        p.bitDepth = Float(bitDepth)
        p.companding = Float(companding)
        p.targetSampleRate = Float(targetSampleRate)
        p.antiAlias = antiAliasing.raw
        p.drive = Float(drive)
        p.saturation = saturation.raw
        p.wowDepth = Float(wowDepth)
        p.wowRate = Float(wowRate)
        p.flutterDepth = Float(flutterDepth)
        p.flutterRate = Float(flutterRate)
        p.noiseLevel = Float(noiseLevel)
        p.crackleDensity = Float(crackleDensity)
        p.highCut = Float(highCut)
        p.mix = Float(mix)
        p.seed = seed
        return p
    }

    /// True when this set touches nothing at all. Asking the C keeps the one definition of bypass
    /// in one place.
    public var isBypass: Bool {
        var p = cParams
        return dg_params_is_bypass(&p) != 0
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case bitDepth, companding, targetSampleRate, antiAliasing, drive, saturation
        case wowDepth, wowRate, flutterDepth, flutterRate
        case noiseLevel, crackleDensity, highCut, mix, seed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DegradeSettings()
        self.init(
            bitDepth: try c.decodeIfPresent(Double.self, forKey: .bitDepth) ?? fallback.bitDepth,
            companding: try c.decodeIfPresent(Double.self, forKey: .companding) ?? fallback.companding,
            targetSampleRate: try c.decodeIfPresent(Double.self, forKey: .targetSampleRate) ?? fallback.targetSampleRate,
            antiAliasing: try c.decodeIfPresent(AntiAliasing.self, forKey: .antiAliasing) ?? fallback.antiAliasing,
            drive: try c.decodeIfPresent(Double.self, forKey: .drive) ?? fallback.drive,
            saturation: try c.decodeIfPresent(Saturation.self, forKey: .saturation) ?? fallback.saturation,
            wowDepth: try c.decodeIfPresent(Double.self, forKey: .wowDepth) ?? fallback.wowDepth,
            wowRate: try c.decodeIfPresent(Double.self, forKey: .wowRate) ?? fallback.wowRate,
            flutterDepth: try c.decodeIfPresent(Double.self, forKey: .flutterDepth) ?? fallback.flutterDepth,
            flutterRate: try c.decodeIfPresent(Double.self, forKey: .flutterRate) ?? fallback.flutterRate,
            noiseLevel: try c.decodeIfPresent(Double.self, forKey: .noiseLevel) ?? fallback.noiseLevel,
            crackleDensity: try c.decodeIfPresent(Double.self, forKey: .crackleDensity) ?? fallback.crackleDensity,
            highCut: try c.decodeIfPresent(Double.self, forKey: .highCut) ?? fallback.highCut,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? fallback.mix,
            seed: try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? fallback.seed
        )
    }
}
