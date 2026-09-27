import Foundation
import SongGraph

// MARK: - Voice kind

/// The voices a synthesized kit provides. One case per physical channel on the machines being
/// modelled, so a preset reads like the front panel — then the hand percussion every kit carries
/// beside its drums (`SynthMachine+Percussion.swift`).
public enum SynthVoiceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case kick, snare, closedHat, openHat, clap, rim
    case lowTom, midTom, highTom, cowbell, crash, ride
    case shaker, tambourine, highConga, lowConga, highBongo, lowBongo, claves, woodblock

    /// The hand percussion, in the order a kit lists it.
    public static let handPercussion: [SynthVoiceKind] = [
        .shaker, .tambourine, .highConga, .lowConga, .highBongo, .lowBongo, .claves, .woodblock,
    ]

    /// The groove-level voice name this kind answers to.
    public var drumVoice: DrumVoice {
        switch self {
        case .kick: return .kick
        case .snare: return .snare
        case .closedHat: return .closedHat
        case .openHat: return .openHat
        case .clap: return .clap
        case .rim: return .rim
        case .lowTom: return .lowTom
        case .midTom: return .midTom
        case .highTom: return .highTom
        case .cowbell: return .cowbell
        case .crash: return .crash
        case .ride: return .ride
        case .shaker: return .shaker
        case .tambourine: return .tambourine
        case .highConga: return .highConga
        case .lowConga: return .lowConga
        case .highBongo: return .highBongo
        case .lowBongo: return .lowBongo
        case .claves: return .claves
        case .woodblock: return .woodblock
        }
    }

    /// The General MIDI percussion note, so a synthesized kit sits on the same keys as an imported
    /// SFZ pack and a groove written for one plays on the other.
    /// <https://www.midi.org/specifications-old/item/gm-level-1-sound-set>
    public var generalMIDINote: Int {
        switch self {
        case .kick: return 36        // Bass Drum 1
        case .rim: return 37         // Side Stick
        case .snare: return 38       // Acoustic Snare
        case .clap: return 39        // Hand Clap
        case .lowTom: return 41      // Low Floor Tom
        case .closedHat: return 42   // Closed Hi-Hat
        case .midTom: return 45      // Low Tom
        case .openHat: return 46     // Open Hi-Hat
        case .highTom: return 48     // Hi-Mid Tom
        case .crash: return 49       // Crash Cymbal 1
        case .ride: return 51        // Ride Cymbal 1
        case .cowbell: return 56     // Cowbell
        case .tambourine: return 54  // Tambourine
        case .highBongo: return 60   // Hi Bongo
        case .lowBongo: return 61    // Low Bongo
        case .highConga: return 63   // Open Hi Conga
        case .lowConga: return 64    // Low Conga
        case .shaker: return 70      // Maracas
        case .claves: return 75      // Claves
        case .woodblock: return 76   // Hi Wood Block
        }
    }

    /// Lower-case, `/`-safe stem for the WAV file a render of this voice is written to.
    public var fileStem: String {
        switch self {
        case .closedHat: return "closed_hat"
        case .openHat: return "open_hat"
        case .lowTom: return "low_tom"
        case .midTom: return "mid_tom"
        case .highTom: return "high_tom"
        case .highConga: return "high_conga"
        case .lowConga: return "low_conga"
        case .highBongo: return "high_bongo"
        case .lowBongo: return "low_bongo"
        default: return rawValue
        }
    }
}

// MARK: - Engine

/// Which generator a voice uses. Named after the circuit topology, not after a DSP idiom, because
/// the point of A3 is that the parameters mean what the schematic means.
public enum SynthEngine: String, Codable, Sendable, Hashable, CaseIterable {
    /// A self-damping bridged-T ring with a pitch envelope: the TR-808's kick, toms and congas.
    case bridgedT
    /// A VCO with a deep, fast pitch envelope plus a separate attack click: the TR-909 kick.
    case pitchedClick
    /// Two detuned tone oscillators plus a filtered noise band: both machines' snares.
    case dualToneNoise
    /// A cluster of square oscillators through a band-pass: the 808's hats, cymbal and cowbell.
    case squareCluster
    /// Repeated short noise bursts plus a longer diffuse tail: the clap.
    case burstNoise
    /// Band-passed noise with a VCA. Used where the hardware played a PCM sample rather than
    /// generating the sound (the TR-909's hats and cymbals) — an honest approximation, not a model.
    case filteredNoise
    /// A short, very high-Q ring: rim shot / side stick.
    case ring
}

// MARK: - Parameter sections

/// Tolerant decoding helper: every section below decodes field by field with a fallback, so a
/// hand-edited `kit.json` may carry only the parameters the author changed.
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
    }
}

/// The controls that exist on the machine's front panel, as normalised knob positions 0…1.
/// These are what a person turns; every one of them maps onto named internals below, and
/// `DrumSynthesizer` applies the mapping rather than reading the knob directly.
public struct SynthControls: Codable, Sendable, Hashable {
    /// TUNE. 0.5 is the detent; the range it covers is per voice (`SynthTone.tuneSemitones`).
    /// On the TR-909's bass drum it moves the pitch *envelope's* length instead of the pitch — see
    /// `SynthTone.pitchEnvelopeShortestSeconds`.
    public var tune: Double
    /// DECAY. Interpolates through `SynthTone.decayShortestSeconds`, `decayMidSeconds` and
    /// `decayLongestSeconds` (and the matching triple on `SynthNoise`).
    public var decay: Double
    /// TONE. **What this is wired to depends on the machine** — see `SynthVoiceSpec.toneControl`.
    /// By default it sweeps the output low-pass between `SynthOutput.toneDarkHz` and `toneBrightHz`,
    /// but on the TR-808's snare it balances the two oscillators and on the TR-909's it sets the
    /// length of the noise.
    public var tone: Double
    /// SNAPPY: the noise channel's gain against the tuned part.
    public var snappy: Double
    /// ATTACK. Only the TR-909's bass drum has this knob, and it is **not** a VCA attack time: it
    /// sets the level of a separate click-and-noise circuit that is mixed with the oscillator.
    /// Scales `SynthClick.level`; 1.0 leaves the preset's level alone.
    /// <http://www.network-909.de/bassdrum.htm>
    public var attack: Double
    /// LEVEL, the channel fader. Linear gain, 1.0 = unity.
    public var level: Double

    public init(tune: Double = 0.5, decay: Double = 0.5, tone: Double = 0.5,
                snappy: Double = 0.5, attack: Double = 1.0, level: Double = 1.0) {
        self.tune = tune; self.decay = decay; self.tone = tone
        self.snappy = snappy; self.attack = attack; self.level = level
    }

    private enum CodingKeys: String, CodingKey { case tune, decay, tone, snappy, attack, level }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthControls()
        tune = c.value(.tune, d.tune)
        decay = c.value(.decay, d.decay)
        tone = c.value(.tone, d.tone)
        snappy = c.value(.snappy, d.snappy)
        attack = c.value(.attack, d.attack)
        level = c.value(.level, d.level)
    }
}

/// The pitched part of a voice: the oscillator(s), their pitch envelope and their VCA.
public struct SynthTone: Codable, Sendable, Hashable {
    /// Centre frequency in Hz at the TUNE detent — the bridged-T's resonance, or the VCO's pitch.
    public var frequencyHz: Double
    /// A second oscillator in Hz, 0 when the voice has only one (the 808 snare has two).
    public var altFrequencyHz: Double
    /// Level of the second oscillator relative to the first.
    public var altLevel: Double
    /// Semitones the TUNE knob covers, end to end, centred on the detent.
    public var tuneSemitones: Double
    /// Frequency in Hz the pitch envelope starts at. 0 means no sweep.
    public var pitchPeakHz: Double
    /// T60 of the pitch envelope's fall from `pitchPeakHz` to `frequencyHz`, in seconds.
    public var pitchEnvelopeSeconds: Double
    /// Pitch-envelope T60 with TUNE fully anticlockwise, in seconds. 0 means the pitch envelope is
    /// fixed and TUNE moves the frequency instead.
    ///
    /// This exists because of the **TR-909 bass drum**, whose TUNE knob is not a pitch control at
    /// all: it sets the decay time of the pitch-sweep envelope, documented as roughly 30 ms to
    /// 120 ms. Turning it changes how long the drop takes, not where the drum ends up.
    /// <http://www.colinfraser.com/tr909/my909.htm>
    public var pitchEnvelopeShortestSeconds: Double
    /// Pitch-envelope T60 with TUNE fully clockwise, in seconds. 0 means fixed.
    public var pitchEnvelopeLongestSeconds: Double
    /// T60 of the tone VCA with DECAY fully anticlockwise, in seconds.
    public var decayShortestSeconds: Double
    /// T60 of the tone VCA at the DECAY detent, in seconds. The TR-808 service notes publish decay
    /// as a SHORT/MID/LONG triple per voice, and the middle value is not the geometric mean of the
    /// other two, so the knob is interpolated through three points rather than two. 0 falls back to
    /// the geometric mean.
    public var decayMidSeconds: Double
    /// T60 of the tone VCA with DECAY fully clockwise, in seconds.
    public var decayLongestSeconds: Double
    /// T60 of the second oscillator, in seconds. 0 means it shares the first oscillator's envelope.
    public var altDecaySeconds: Double
    /// Rise time of the tone VCA, in seconds. The hardware's trigger pulse is not instantaneous.
    public var attackSeconds: Double
    /// Linear level of the tone path before the SNAPPY balance.
    public var level: Double
    /// Square-oscillator cluster in Hz, for `squareCluster` voices.
    public var partialsHz: [Double]

    public init(frequencyHz: Double = 60, altFrequencyHz: Double = 0, altLevel: Double = 0,
                tuneSemitones: Double = 12, pitchPeakHz: Double = 0,
                pitchEnvelopeSeconds: Double = 0.006,
                pitchEnvelopeShortestSeconds: Double = 0, pitchEnvelopeLongestSeconds: Double = 0,
                decayShortestSeconds: Double = 0.05, decayMidSeconds: Double = 0,
                decayLongestSeconds: Double = 0.8, altDecaySeconds: Double = 0,
                attackSeconds: Double = 0.0005, level: Double = 1,
                partialsHz: [Double] = []) {
        self.frequencyHz = frequencyHz
        self.altFrequencyHz = altFrequencyHz
        self.altLevel = altLevel
        self.tuneSemitones = tuneSemitones
        self.pitchPeakHz = pitchPeakHz
        self.pitchEnvelopeSeconds = pitchEnvelopeSeconds
        self.pitchEnvelopeShortestSeconds = pitchEnvelopeShortestSeconds
        self.pitchEnvelopeLongestSeconds = pitchEnvelopeLongestSeconds
        self.decayShortestSeconds = decayShortestSeconds
        self.decayMidSeconds = decayMidSeconds
        self.decayLongestSeconds = decayLongestSeconds
        self.altDecaySeconds = altDecaySeconds
        self.attackSeconds = attackSeconds
        self.level = level
        self.partialsHz = partialsHz
    }

    private enum CodingKeys: String, CodingKey {
        case frequencyHz, altFrequencyHz, altLevel, tuneSemitones, pitchPeakHz
        case pitchEnvelopeSeconds, pitchEnvelopeShortestSeconds, pitchEnvelopeLongestSeconds
        case decayShortestSeconds, decayMidSeconds, decayLongestSeconds
        case altDecaySeconds, attackSeconds, level, partialsHz
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthTone()
        frequencyHz = c.value(.frequencyHz, d.frequencyHz)
        altFrequencyHz = c.value(.altFrequencyHz, d.altFrequencyHz)
        altLevel = c.value(.altLevel, d.altLevel)
        tuneSemitones = c.value(.tuneSemitones, d.tuneSemitones)
        pitchPeakHz = c.value(.pitchPeakHz, d.pitchPeakHz)
        pitchEnvelopeSeconds = c.value(.pitchEnvelopeSeconds, d.pitchEnvelopeSeconds)
        pitchEnvelopeShortestSeconds = c.value(.pitchEnvelopeShortestSeconds, d.pitchEnvelopeShortestSeconds)
        pitchEnvelopeLongestSeconds = c.value(.pitchEnvelopeLongestSeconds, d.pitchEnvelopeLongestSeconds)
        decayShortestSeconds = c.value(.decayShortestSeconds, d.decayShortestSeconds)
        decayMidSeconds = c.value(.decayMidSeconds, d.decayMidSeconds)
        decayLongestSeconds = c.value(.decayLongestSeconds, d.decayLongestSeconds)
        altDecaySeconds = c.value(.altDecaySeconds, d.altDecaySeconds)
        attackSeconds = c.value(.attackSeconds, d.attackSeconds)
        level = c.value(.level, d.level)
        partialsHz = c.value(.partialsHz, d.partialsHz)
    }

    /// The tuned frequency for a TUNE knob position, in Hz.
    public func frequency(tune: Double) -> Double {
        frequencyHz * pow(2, (tune - 0.5) * tuneSemitones / 12)
    }

    /// The pitch envelope's T60 for a TUNE knob position. Fixed unless the voice is one whose TUNE
    /// knob sweeps the pitch envelope rather than the pitch — see `pitchEnvelopeShortestSeconds`.
    public func pitchEnvelope(tune: Double) -> Double {
        guard pitchEnvelopeLongestSeconds > 0, pitchEnvelopeShortestSeconds > 0 else {
            return pitchEnvelopeSeconds
        }
        let t = min(max(tune, 0), 1)
        return pitchEnvelopeShortestSeconds
            * pow(pitchEnvelopeLongestSeconds / pitchEnvelopeShortestSeconds, t)
    }

    /// The tone VCA's T60 for a DECAY knob position. Geometric interpolation through the
    /// SHORT/MID/LONG triple — a decay knob is a resistance, and hearing is logarithmic in time as
    /// well as in level.
    public func decaySeconds(decay: Double) -> Double {
        SynthInterpolation.decay(decay, shortest: decayShortestSeconds,
                                 middle: decayMidSeconds, longest: decayLongestSeconds)
    }
}

/// The noise part of a voice: its generator, band and VCA.
public struct SynthNoise: Codable, Sendable, Hashable {
    /// Linear level of the noise path before the SNAPPY balance. 0 means the voice has no noise.
    public var level: Double
    /// Band-pass centre in Hz.
    public var bandHz: Double
    /// Band-pass Q.
    public var bandQ: Double
    /// A high-pass ahead of the band-pass, in Hz. 0 skips it.
    public var highPassHz: Double
    /// T60 of the noise VCA with DECAY fully anticlockwise, in seconds.
    public var decayShortestSeconds: Double
    /// T60 of the noise VCA at the DECAY detent, in seconds. 0 uses the geometric mean.
    public var decayMidSeconds: Double
    /// T60 of the noise VCA with DECAY fully clockwise, in seconds.
    public var decayLongestSeconds: Double
    /// Rise time of the noise VCA, in seconds.
    public var attackSeconds: Double

    public init(level: Double = 0, bandHz: Double = 2_000, bandQ: Double = 1,
                highPassHz: Double = 0, decayShortestSeconds: Double = 0.05,
                decayMidSeconds: Double = 0, decayLongestSeconds: Double = 0.3,
                attackSeconds: Double = 0.0003) {
        self.level = level
        self.bandHz = bandHz
        self.bandQ = bandQ
        self.highPassHz = highPassHz
        self.decayShortestSeconds = decayShortestSeconds
        self.decayMidSeconds = decayMidSeconds
        self.decayLongestSeconds = decayLongestSeconds
        self.attackSeconds = attackSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case level, bandHz, bandQ, highPassHz
        case decayShortestSeconds, decayMidSeconds, decayLongestSeconds, attackSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthNoise()
        level = c.value(.level, d.level)
        bandHz = c.value(.bandHz, d.bandHz)
        bandQ = c.value(.bandQ, d.bandQ)
        highPassHz = c.value(.highPassHz, d.highPassHz)
        decayShortestSeconds = c.value(.decayShortestSeconds, d.decayShortestSeconds)
        decayMidSeconds = c.value(.decayMidSeconds, d.decayMidSeconds)
        decayLongestSeconds = c.value(.decayLongestSeconds, d.decayLongestSeconds)
        attackSeconds = c.value(.attackSeconds, d.attackSeconds)
    }

    public func decaySeconds(decay: Double) -> Double {
        SynthInterpolation.decay(decay, shortest: decayShortestSeconds,
                                 middle: decayMidSeconds, longest: decayLongestSeconds)
    }
}

/// The attack transient: the click a kick's trigger pulse leaves before the oscillator takes over.
public struct SynthClick: Codable, Sendable, Hashable {
    public var level: Double
    /// T60 of the click, in seconds.
    public var decaySeconds: Double
    /// High-pass ahead of the click, in Hz — a click is what survives above the body.
    public var highPassHz: Double
    /// Fraction of the click that is noise rather than pulse, 0…1.
    public var noiseFraction: Double
    /// Whether the click is summed **after** the voice's output filter rather than through it.
    ///
    /// This is a real difference between the two machines. On the TR-808 the trigger pulse enters
    /// the bridged-T network itself, so the TONE low-pass that follows acts on the click too —
    /// Roland's own description is that TONE "can be used to reduce the transient click". On the
    /// TR-909 the ATTACK circuit is a separate pulse-plus-noise generator with its own VCA, mixed
    /// with the oscillator at IC11a, downstream of the voice's filtering — which is why a 909's
    /// click survives everything and cuts through a mix.
    /// <https://www.baratatronix.com/blog/808-bd-synthesis> and
    /// <http://www.network-909.de/bassdrum.htm>
    public var postFilter: Bool

    public init(level: Double = 0, decaySeconds: Double = 0.003,
                highPassHz: Double = 1_000, noiseFraction: Double = 0.5,
                postFilter: Bool = false) {
        self.level = level
        self.decaySeconds = decaySeconds
        self.highPassHz = highPassHz
        self.noiseFraction = noiseFraction
        self.postFilter = postFilter
    }

    private enum CodingKeys: String, CodingKey {
        case level, decaySeconds, highPassHz, noiseFraction, postFilter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthClick()
        level = c.value(.level, d.level)
        decaySeconds = c.value(.decaySeconds, d.decaySeconds)
        highPassHz = c.value(.highPassHz, d.highPassHz)
        noiseFraction = c.value(.noiseFraction, d.noiseFraction)
        postFilter = c.value(.postFilter, d.postFilter)
    }
}

/// The clap's retriggered bursts and its diffuse tail.
public struct SynthBurst: Codable, Sendable, Hashable {
    /// How many fast bursts precede the tail.
    public var count: Int
    /// Seconds between burst onsets.
    public var intervalSeconds: Double
    /// T60 of one burst, in seconds.
    public var burstDecaySeconds: Double
    /// Level of the tail relative to a burst.
    public var tailLevel: Double
    /// T60 of the tail, in seconds.
    public var tailDecaySeconds: Double

    public init(count: Int = 3, intervalSeconds: Double = 0.01,
                burstDecaySeconds: Double = 0.01, tailLevel: Double = 0.7,
                tailDecaySeconds: Double = 0.24) {
        self.count = count
        self.intervalSeconds = intervalSeconds
        self.burstDecaySeconds = burstDecaySeconds
        self.tailLevel = tailLevel
        self.tailDecaySeconds = tailDecaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case count, intervalSeconds, burstDecaySeconds, tailLevel, tailDecaySeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthBurst()
        count = c.value(.count, d.count)
        intervalSeconds = c.value(.intervalSeconds, d.intervalSeconds)
        burstDecaySeconds = c.value(.burstDecaySeconds, d.burstDecaySeconds)
        tailLevel = c.value(.tailLevel, d.tailLevel)
        tailDecaySeconds = c.value(.tailDecaySeconds, d.tailDecaySeconds)
    }
}

/// The output stage: the TONE control's low-pass, a fixed high-pass, and the saturation of the
/// transistor stages between the voice and the mixer.
public struct SynthOutput: Codable, Sendable, Hashable {
    /// Low-pass corner in Hz with TONE fully anticlockwise.
    public var toneDarkHz: Double
    /// Low-pass corner in Hz with TONE fully clockwise.
    public var toneBrightHz: Double
    /// A fixed high-pass in Hz, applied after everything. 0 skips it.
    public var highPassHz: Double
    /// Saturation amount, 0…1. See `SynthShaper.saturate`.
    public var drive: Double

    public init(toneDarkHz: Double = 4_000, toneBrightHz: Double = 18_000,
                highPassHz: Double = 0, drive: Double = 0) {
        self.toneDarkHz = toneDarkHz
        self.toneBrightHz = toneBrightHz
        self.highPassHz = highPassHz
        self.drive = drive
    }

    private enum CodingKeys: String, CodingKey { case toneDarkHz, toneBrightHz, highPassHz, drive }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthOutput()
        toneDarkHz = c.value(.toneDarkHz, d.toneDarkHz)
        toneBrightHz = c.value(.toneBrightHz, d.toneBrightHz)
        highPassHz = c.value(.highPassHz, d.highPassHz)
        drive = c.value(.drive, d.drive)
    }

    /// Low-pass corner in Hz for a TONE knob position, interpolated geometrically.
    public func toneHz(_ tone: Double) -> Double {
        let t = min(max(tone, 0), 1)
        return toneDarkHz * pow(toneBrightHz / toneDarkHz, t)
    }
}

/// How a hit's velocity changes the voice.
///
/// **On a real 808 accent is almost entirely level** — there is one ACCENT bus and it raises the
/// trigger-pulse voltage feeding every enabled voice. The trigger pulse is 3.5 V un-accented and
/// rises to 13.5 V fully accented, which on the kick also drives the pitch envelope's peak a little
/// higher and lets the bridged-T ring slightly longer. The small non-level terms below are that
/// second-order effect and nothing more; they are what makes two pre-rendered layers worth having
/// instead of one sample and a volume knob.
/// <https://www.baratatronix.com/blog/808-bd-synthesis>
public struct SynthVelocity: Codable, Sendable, Hashable {
    /// dB from velocity 1 to velocity 127, applied inside `render`.
    public var rangeDB: Double
    /// Cents the pitch envelope's peak rises by at full velocity.
    public var pitchCents: Double
    /// Multiplier on the decay time at full velocity (1.0 = velocity does not change decay).
    public var decayFactor: Double
    /// Multiplier on the output low-pass corner at full velocity — harder hits are brighter.
    public var brightnessFactor: Double

    public init(rangeDB: Double = 18, pitchCents: Double = 0,
                decayFactor: Double = 1, brightnessFactor: Double = 1) {
        self.rangeDB = rangeDB
        self.pitchCents = pitchCents
        self.decayFactor = decayFactor
        self.brightnessFactor = brightnessFactor
    }

    private enum CodingKeys: String, CodingKey { case rangeDB, pitchCents, decayFactor, brightnessFactor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthVelocity()
        rangeDB = c.value(.rangeDB, d.rangeDB)
        pitchCents = c.value(.pitchCents, d.pitchCents)
        decayFactor = c.value(.decayFactor, d.decayFactor)
        brightnessFactor = c.value(.brightnessFactor, d.brightnessFactor)
    }
}

/// The sampled-machine flavour: bit depth and playback rate of a voice that, in hardware, was a
/// companded PCM sample in ROM rather than a circuit. Absent on the purely analog voices.
public struct SynthSampled: Codable, Sendable, Hashable {
    /// Bits of companded resolution. 0 leaves the signal alone.
    public var bits: Int
    /// The rate the ROM was clocked out at, in Hz. 0 leaves the signal alone.
    public var playbackRateHz: Double

    public init(bits: Int = 8, playbackRateHz: Double = 28_000) {
        self.bits = bits
        self.playbackRateHz = playbackRateHz
    }

    private enum CodingKeys: String, CodingKey { case bits, playbackRateHz }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthSampled()
        bits = c.value(.bits, d.bits)
        playbackRateHz = c.value(.playbackRateHz, d.playbackRateHz)
    }
}

/// What a voice's TONE knob is wired to. It is not the same thing on every machine, and getting it
/// wrong is the commonest error in drum-machine emulation.
public enum SynthToneControl: String, Codable, Sendable, Hashable, CaseIterable {
    /// TONE sweeps the output low-pass between `SynthOutput.toneDarkHz` and `toneBrightHz`. The
    /// TR-808 bass drum's passive low-pass is this.
    case outputLowPass
    /// TONE sets the balance between the two tuned oscillators. The **TR-808 snare**: Roland
    /// describes VR8 as setting "the output ratio of the two" bridged-T networks.
    /// <https://archive.org/stream/synthmanual-roland-tr-808-service-notes/rolandtr-808servicenotes_djvu.txt>
    case oscillatorBalance
    /// TONE sets the length of the noise. The **TR-909 snare**, where TONE is a decay control on the
    /// noise envelope rather than a filter — the opposite of what the name suggests.
    /// <https://www.tiptopaudio.com/manuals/Tiptop_Audio_SD909_ns.pdf>
    case noiseDecay
}

// MARK: - Spec

/// Everything needed to render one voice, deterministically.
///
/// The parameters are deliberately in two layers: `controls` is the front panel (TUNE, DECAY, TONE,
/// SNAPPY, LEVEL), and `tone`/`noise`/`click`/`burst`/`output` are the internals those knobs sweep.
/// A preset sets the internals from the circuit; a person turns the knobs.
public struct SynthVoiceSpec: Codable, Sendable, Hashable, Identifiable {
    public var kind: SynthVoiceKind
    public var engine: SynthEngine
    /// The machine this spec came from, e.g. `"tr808"`. Recorded so a kit says where it came from
    /// and a re-render after an edit can be told apart from the factory preset.
    public var machine: String
    public var controls: SynthControls
    /// What this voice's TONE knob is wired to.
    public var toneControl: SynthToneControl
    public var tone: SynthTone
    public var noise: SynthNoise
    public var click: SynthClick
    /// Only the clap has one.
    public var burst: SynthBurst?
    public var output: SynthOutput
    public var velocity: SynthVelocity
    /// Only the voices whose hardware played PCM have one.
    public var sampled: SynthSampled?
    /// How long a render is, in seconds. Long enough for the longest decay the knobs reach plus the
    /// fade-out; the synthesizer does not grow the buffer to fit.
    public var durationSeconds: Double
    /// Seed for every stochastic element. Part of the spec — that is the whole determinism story.
    public var seed: UInt64

    public var id: SynthVoiceKind { kind }

    public init(kind: SynthVoiceKind, engine: SynthEngine, machine: String,
                controls: SynthControls = SynthControls(),
                toneControl: SynthToneControl = .outputLowPass,
                tone: SynthTone = SynthTone(), noise: SynthNoise = SynthNoise(),
                click: SynthClick = SynthClick(), burst: SynthBurst? = nil,
                output: SynthOutput = SynthOutput(), velocity: SynthVelocity = SynthVelocity(),
                sampled: SynthSampled? = nil,
                durationSeconds: Double = 1.0, seed: UInt64 = 1) {
        self.kind = kind
        self.engine = engine
        self.machine = machine
        self.controls = controls
        self.toneControl = toneControl
        self.tone = tone
        self.noise = noise
        self.click = click
        self.burst = burst
        self.output = output
        self.velocity = velocity
        self.sampled = sampled
        self.durationSeconds = durationSeconds
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey {
        case kind, engine, machine, controls, toneControl, tone, noise, click, burst, output, velocity
        case sampled, durationSeconds, seed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SynthVoiceKind.self, forKey: .kind)
        engine = try c.decode(SynthEngine.self, forKey: .engine)
        machine = c.value(.machine, "custom")
        controls = c.value(.controls, SynthControls())
        toneControl = c.value(.toneControl, SynthToneControl.outputLowPass)
        tone = c.value(.tone, SynthTone())
        noise = c.value(.noise, SynthNoise())
        click = c.value(.click, SynthClick())
        burst = try c.decodeIfPresent(SynthBurst.self, forKey: .burst)
        output = c.value(.output, SynthOutput())
        velocity = c.value(.velocity, SynthVelocity())
        sampled = try c.decodeIfPresent(SynthSampled.self, forKey: .sampled)
        durationSeconds = c.value(.durationSeconds, 1.0)
        seed = c.value(.seed, UInt64(1))
    }
}
