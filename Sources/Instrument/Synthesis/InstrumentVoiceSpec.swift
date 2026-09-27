import Foundation

// MARK: - A pitched, sustaining instrument

/// A synthesized instrument voice: keys, pads, plucks and leads.
///
/// The drums (`SynthMachine`) are one-shots and the bass (`BassVoiceSpec`) is one note at a time in
/// one register. This is the third kind: a voice that sustains, is played in chords, and has to
/// hold up from the bottom of the piano to the top. Like both of the others it is a *generator* the
/// sampler plays — rendered to a pitched kit once and cached — so a note costs a sample lookup at
/// play time rather than a synth voice, and two renders of the same preset are the same bytes.
///
/// Two engines, because between them they cover most of what a record needs and they fail in
/// opposite directions:
///
/// * **Subtractive** is oscillators into a resonant low-pass with an envelope on it. Detuned saws
///   are a pad, a square with a fast filter envelope is a pluck, a slow one is brass. This is the
///   Juno and Prophet architecture, and what it cannot do is bells and electric pianos: their
///   partials are not harmonic, and no amount of filtering a saw will make them.
/// * **FM** is four operators, each a sine modulating the next by a ratio. Inharmonic ratios give
///   bells, glass and the tines of an electric piano — the sounds subtractive cannot reach — and
///   its brightness follows how hard the operator is driven, which is why velocity matters more
///   here and why the presets that use it ask for two velocity layers.
public struct InstrumentVoiceSpec: Codable, Sendable, Hashable, Identifiable {

    public enum Engine: String, Codable, Sendable, Hashable, CaseIterable {
        case subtractive
        case fm
        /// A plucked string: a burst ringing down a delay line (Karplus–Strong), the bass's played
        /// voice made to cover the whole keyboard. Guitars, harp, koto, pizzicato.
        case pluckedString
        /// Not synthesized at all: recordings brought in from an SFZ pack, played from the kit in
        /// `sampledKit`. See `ImportedInstruments`.
        case sampled
    }

    /// A plucked string's settings (`Engine.pluckedString`).
    public struct Pluck: Codable, Sendable, Hashable {
        /// How long the string rings at middle C before it is 60 dB down, seconds.
        public var decaySeconds: Double
        /// How far the ring follows the note: 0 rings as long at the top as the bottom; 1 halves
        /// it every octave up, which is closer to a real string.
        public var decayKeyTrack: Double
        /// How bright the pluck is at full velocity: the low-pass on the burst, in Hz.
        public var brightnessHz: Double
        /// Where along the string it is plucked, 0…0.5: near the bridge is thin and bright, the
        /// middle round and hollow. It notches the harmonics that have a node there.
        public var pickPosition: Double

        public init(decaySeconds: Double, decayKeyTrack: Double = 0.5, brightnessHz: Double = 4_000, pickPosition: Double = 0.18) {
            self.decaySeconds = decaySeconds
            self.decayKeyTrack = decayKeyTrack
            self.brightnessHz = brightnessHz
            self.pickPosition = pickPosition
        }
    }

    /// A slow wobble: vibrato bends the pitch by `depth` cents, tremolo dips the level by `depth`
    /// (0…1). Both fade in over `delaySeconds`, as a player's does after the note has started.
    public struct Modulation: Codable, Sendable, Hashable {
        public var rateHz: Double
        public var depth: Double
        public var delaySeconds: Double

        public init(rateHz: Double, depth: Double, delaySeconds: Double = 0.3) {
            self.rateHz = rateHz
            self.depth = depth
            self.delaySeconds = delaySeconds
        }
    }

    /// What an oscillator puts out before the filter. All are band-limited by rendering at the
    /// working rate and low-passing; at the top of the keyboard a naive saw would alias badly, so
    /// `Oscillator.sample` sums harmonics up to Nyquist rather than using a jump discontinuity.
    public enum Waveform: String, Codable, Sendable, Hashable, CaseIterable {
        case sine, triangle, saw, square, pulse
    }

    /// One oscillator of a subtractive voice.
    public struct Oscillator: Codable, Sendable, Hashable {
        public var waveform: Waveform
        /// Whole octaves from the played note. −1 is an octave down.
        public var octave: Int
        /// Fine detune in cents, which is what makes two saws into a chorus.
        public var cents: Double
        public var level: Double
        /// Pulse width for `.pulse`, 0…1, ignored otherwise.
        public var pulseWidth: Double

        public init(waveform: Waveform, octave: Int = 0, cents: Double = 0, level: Double = 1, pulseWidth: Double = 0.5) {
            self.waveform = waveform
            self.octave = octave
            self.cents = cents
            self.level = level
            self.pulseWidth = pulseWidth
        }
    }

    /// One FM operator: a sine at a ratio of the played pitch, with its own envelope.
    ///
    /// `ratio` is against the note, so 1 is the fundamental and 3.5 is inharmonic, which is where
    /// bells come from. A carrier's `level` is its share of the output; a modulator's `level` is
    /// how far it bends whatever it is modulating, in index rather than decibels.
    public struct Operator: Codable, Sendable, Hashable {
        public var ratio: Double
        public var level: Double
        public var attack: Double
        public var decay: Double
        public var sustain: Double
        /// Fixed frequency in Hz instead of a ratio of the note, for a fixed-pitch clank.
        public var fixedHz: Double?

        public init(ratio: Double, level: Double, attack: Double = 0.001, decay: Double = 1,
                    sustain: Double = 0, fixedHz: Double? = nil) {
            self.ratio = ratio
            self.level = level
            self.attack = attack
            self.decay = decay
            self.sustain = sustain
            self.fixedHz = fixedHz
        }
    }

    /// How the four operators are wired. The classic shapes, not all thirty-two of the DX7's.
    public enum Algorithm: String, Codable, Sendable, Hashable, CaseIterable {
        /// How it reads on a surface, rather than how it is spelled in code.
        public var title: String {
            switch self {
            case .stack: return "a chain of four"
            case .twoIntoOne: return "two modulators into one"
            case .twinPairs: return "two pairs"
            case .onePairTwoSines: return "a pair and two sines"
            }
        }

        /// 4→3→2→1: one chain into one carrier. The brightest and the most extreme.
        case stack
        /// 4→3→1 and 2→1: two modulators into one carrier.
        case twoIntoOne
        /// 2→1 and 4→3, summed: two independent pairs. Electric pianos live here.
        case twinPairs
        /// 2→1, plus 3 and 4 as carriers of their own: one modulated voice and two sines.
        case onePairTwoSines
    }

    /// Attack, decay, sustain and release in seconds, sustain as a level.
    public struct Envelope: Codable, Sendable, Hashable {
        public var attack: Double
        public var decay: Double
        public var sustain: Double
        public var release: Double

        public init(attack: Double = 0.005, decay: Double = 0.3, sustain: Double = 0.7, release: Double = 0.25) {
            self.attack = attack
            self.decay = decay
            self.sustain = sustain
            self.release = release
        }
    }

    public var id: String
    public var name: String
    /// What a persona or a picker says this is for: "keys", "pad", "pluck", "lead", "bell".
    public var family: String
    public var engine: Engine
    /// What it sounds like, in a player's words, for the picker. Empty says it in its own terms.
    public var summary: String
    /// `Engine.pluckedString` only.
    public var pluck: Pluck?
    public var vibrato: Modulation?
    public var tremolo: Modulation?
    /// `Engine.sampled` only: the folder holding its kit, set when the instrument is registered.
    /// Not part of what it sounds like, so it is never written to its `instrument.json`.
    public var sampledKit: String?

    // Subtractive
    public var oscillators: [Oscillator]
    /// A sine an octave below the note, mixed under the oscillators. 0 is off.
    public var subLevel: Double
    /// White noise mixed in before the filter, for breath. 0 is off.
    public var noiseLevel: Double
    /// Low-pass corner in Hz at `filterReferenceMIDI`, before the envelope opens it.
    public var filterHz: Double
    public var filterReferenceMIDI: Int
    /// How far the corner follows the note: 1 tracks it exactly, 0 keeps it fixed.
    public var filterKeyTrack: Double
    public var filterQ: Double
    /// Octaves the filter envelope opens the corner by, at full velocity.
    public var filterEnvelopeOctaves: Double
    public var filterEnvelope: Envelope

    // FM
    public var algorithm: Algorithm
    public var operators: [Operator]

    // Both
    public var amplitude: Envelope
    /// Saturation into the output, 0…1.
    public var drive: Double
    public var level: Double
    /// Seconds each note is rendered for. A held note longer than this rides the release out.
    public var durationSeconds: Double
    /// Velocities to render a layer at. One layer is level-only velocity; two or more let the
    /// timbre change with how hard it is played, which is what FM and a filter envelope want.
    public var velocityLayers: [Int]

    public init(id: String, name: String, family: String, engine: Engine, summary: String = "",
                pluck: Pluck? = nil, vibrato: Modulation? = nil, tremolo: Modulation? = nil,
                oscillators: [Oscillator] = [], subLevel: Double = 0, noiseLevel: Double = 0,
                filterHz: Double = 12_000, filterReferenceMIDI: Int = 60, filterKeyTrack: Double = 0.5,
                filterQ: Double = 0.8, filterEnvelopeOctaves: Double = 0,
                filterEnvelope: Envelope = Envelope(attack: 0.002, decay: 0.4, sustain: 0.3, release: 0.2),
                algorithm: Algorithm = .twinPairs, operators: [Operator] = [],
                amplitude: Envelope = Envelope(), drive: Double = 0, level: Double = 1,
                durationSeconds: Double = 4, velocityLayers: [Int] = [110], sampledKit: String? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.engine = engine
        self.summary = summary
        self.pluck = pluck
        self.vibrato = vibrato
        self.tremolo = tremolo
        self.oscillators = oscillators
        self.subLevel = subLevel
        self.noiseLevel = noiseLevel
        self.filterHz = filterHz
        self.filterReferenceMIDI = filterReferenceMIDI
        self.filterKeyTrack = filterKeyTrack
        self.filterQ = filterQ
        self.filterEnvelopeOctaves = filterEnvelopeOctaves
        self.filterEnvelope = filterEnvelope
        self.algorithm = algorithm
        self.operators = operators
        self.amplitude = amplitude
        self.drive = drive
        self.level = level
        self.durationSeconds = durationSeconds
        self.velocityLayers = velocityLayers.isEmpty ? [110] : velocityLayers.sorted()
        self.sampledKit = sampledKit
    }
}

// MARK: - The presets

public extension InstrumentVoiceSpec {

    /// Everything the app ships. Ordered by family so a picker reads as a keyboard's bank list.
    static let all: [InstrumentVoiceSpec] = [
        // Keys
        rhodes, wurlitzer, fmPiano, feltPiano, clavinet, harpsichord, toyPiano, juno,
        // Organs
        organ, rockOrgan, pipeOrgan, harmonium, comboOrgan,
        // Mallets and bells
        bell, marimba, vibraphone, xylophone, glockenspiel, kalimba, steelDrum, musicBox, tubularBells,
        // Plucked strings
        nylonGuitar, steelGuitar, cleanElectric, mutedGuitar, harp, koto, banjo, pizzicato,
        // Bowed strings
        stringSection, slowStrings, violin, cello,
        // Pads and voices
        warmPad, choir, vocalOohs, glassPad, darkPad, airPad, sweepPad,
        // Winds
        flute, clarinet, oboe, panFlute,
        // Brass
        brass, synthBrass, trumpet, frenchHorns,
        // Synth plucks
        pluck, bellPluck, houseStab,
        // Leads
        squareLead, sawLead, sineLead,
        // Chip
        chipSquare, chipPulse, chipTriangle,
    ]

    /// A preset, or an instrument imported into this app, by id.
    static func preset(id: String) -> InstrumentVoiceSpec? {
        all.first { $0.id == id } ?? ImportedInstruments.spec(id: id)
    }

    /// What a picker offers: the presets, then what has been imported.
    static var available: [InstrumentVoiceSpec] { all + ImportedInstruments.all }

    // MARK: FM — the sounds subtractive cannot reach

    /// An electric piano: a tine. Two pairs — a near-harmonic body and a bright inharmonic strike
    /// that decays fast, which is the tine being hit and then ringing.
    static let rhodes = InstrumentVoiceSpec(
        id: "rhodes", name: "Rhodes", family: "keys", engine: .fm,
        summary: "Electric piano, warm and bell-toned; brighter the harder you play.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.002, decay: 2.6, sustain: 0.18),
            Operator(ratio: 1, level: 0.62, attack: 0.001, decay: 0.55, sustain: 0.04),
            Operator(ratio: 1, level: 0.30, attack: 0.001, decay: 1.2, sustain: 0.08),
            Operator(ratio: 14, level: 0.55, attack: 0.001, decay: 0.09, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.002, decay: 2.8, sustain: 0.16, release: 0.35),
        drive: 0.12, level: 0.9, durationSeconds: 5, velocityLayers: [45, 110])

    /// The reedier electric piano: one pair, more index, a harder bark at the front.
    static let wurlitzer = InstrumentVoiceSpec(
        id: "wurlitzer", name: "Wurlitzer", family: "keys", engine: .fm,
        summary: "Reedy electric piano, with more bite than the Rhodes.",
        algorithm: .twoIntoOne,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.002, decay: 1.8, sustain: 0.14),
            Operator(ratio: 2, level: 0.78, attack: 0.001, decay: 0.7, sustain: 0.06),
            Operator(ratio: 5, level: 0.42, attack: 0.001, decay: 0.16, sustain: 0),
            Operator(ratio: 1, level: 0, attack: 0.001, decay: 0.1, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.002, decay: 2, sustain: 0.12, release: 0.3),
        drive: 0.3, level: 0.9, durationSeconds: 4, velocityLayers: [45, 110])

    /// A struck bell: inharmonic ratios, long decay, no sustain.
    ///
    /// The modulation index is deliberately lower than a physical bell's. Drive it harder and the
    /// carrier's energy spreads into the 2.51 sideband until *that* is the loudest partial, which
    /// is exactly what a real bell does and why a bell's strike tone is not the note you struck.
    /// Here the note has to read, because melodies get written on this.
    static let bell = InstrumentVoiceSpec(
        id: "bell", name: "Bell", family: "bell", engine: .fm,
        summary: "Clear, ringing bells, for a tune that should cut through.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 4, sustain: 0),
            Operator(ratio: 3.51, level: 0.34, attack: 0.001, decay: 2.2, sustain: 0),
            Operator(ratio: 2.01, level: 0.26, attack: 0.001, decay: 3, sustain: 0),
            Operator(ratio: 8.2, level: 0.26, attack: 0.001, decay: 0.7, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 4.5, sustain: 0, release: 0.6),
        level: 0.8, durationSeconds: 5)

    /// Wood, not metal: a low index and a fast decay make a struck bar.
    static let marimba = InstrumentVoiceSpec(
        id: "marimba", name: "Marimba", family: "bell", engine: .fm,
        summary: "Wooden mallets: short, round and soft-edged.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 0.7, sustain: 0),
            Operator(ratio: 4, level: 0.5, attack: 0.001, decay: 0.12, sustain: 0),
            Operator(ratio: 1, level: 0.25, attack: 0.001, decay: 0.45, sustain: 0),
            Operator(ratio: 9.4, level: 0.2, attack: 0.001, decay: 0.05, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 0.85, sustain: 0, release: 0.2),
        level: 0.85, durationSeconds: 2)

    // MARK: Subtractive — oscillators into a filter

    /// The eighties polysynth: three saws a few cents apart, filter half open.
    static let juno = InstrumentVoiceSpec(
        id: "juno", name: "Poly Saws", family: "keys", engine: .subtractive,
        summary: "Bright stacked saws, for chords that fill the room.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -7, level: 0.9),
            Oscillator(waveform: .saw, cents: 6, level: 0.9),
            Oscillator(waveform: .pulse, cents: 0, level: 0.5, pulseWidth: 0.35),
        ],
        subLevel: 0.25,
        filterHz: 1_900, filterKeyTrack: 0.6, filterQ: 0.9, filterEnvelopeOctaves: 1.4,
        filterEnvelope: Envelope(attack: 0.01, decay: 0.8, sustain: 0.35, release: 0.35),
        amplitude: Envelope(attack: 0.01, decay: 1.2, sustain: 0.65, release: 0.4),
        drive: 0.1, level: 0.8, durationSeconds: 4, velocityLayers: [50, 112])

    /// A slow pad: detuned saws, the filter crawling open over a second.
    static let warmPad = InstrumentVoiceSpec(
        id: "pad", name: "Warm Pad", family: "pad", engine: .subtractive,
        summary: "A soft pad that swells in slowly behind everything.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -11, level: 0.8),
            Oscillator(waveform: .saw, cents: 9, level: 0.8),
            Oscillator(waveform: .triangle, octave: -1, level: 0.5),
        ],
        noiseLevel: 0.03,
        filterHz: 700, filterKeyTrack: 0.45, filterQ: 0.9, filterEnvelopeOctaves: 1.8,
        filterEnvelope: Envelope(attack: 1.1, decay: 1.5, sustain: 0.6, release: 1),
        amplitude: Envelope(attack: 0.7, decay: 1.5, sustain: 0.8, release: 1.2),
        level: 0.7, durationSeconds: 6)

    /// Breathy and narrow: a triangle pair with noise, filtered low.
    static let choir = InstrumentVoiceSpec(
        id: "choir", name: "Choir", family: "pad", engine: .subtractive,
        summary: "An airy, voice-like pad.",
        oscillators: [
            Oscillator(waveform: .triangle, cents: -8, level: 0.9),
            Oscillator(waveform: .triangle, cents: 7, level: 0.9),
            Oscillator(waveform: .sine, octave: 1, level: 0.2),
        ],
        noiseLevel: 0.07,
        filterHz: 1_100, filterKeyTrack: 0.7, filterQ: 1.4, filterEnvelopeOctaves: 0.8,
        filterEnvelope: Envelope(attack: 0.6, decay: 1.2, sustain: 0.7, release: 0.9),
        amplitude: Envelope(attack: 0.45, decay: 1.2, sustain: 0.85, release: 1),
        level: 0.7, durationSeconds: 6)

    /// A pluck: the filter slams shut in a tenth of a second.
    static let pluck = InstrumentVoiceSpec(
        id: "pluck", name: "Pluck", family: "pluck", engine: .subtractive,
        summary: "A short plucked synth, for riffs and arpeggios.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -4, level: 0.9),
            Oscillator(waveform: .square, cents: 5, level: 0.6),
        ],
        filterHz: 500, filterKeyTrack: 0.8, filterQ: 2.2, filterEnvelopeOctaves: 3.2,
        filterEnvelope: Envelope(attack: 0.001, decay: 0.16, sustain: 0.05, release: 0.12),
        amplitude: Envelope(attack: 0.001, decay: 0.7, sustain: 0.12, release: 0.2),
        drive: 0.15, level: 0.85, durationSeconds: 3, velocityLayers: [50, 112])

    /// Drawbars: octaves stacked as sines, no filter movement at all.
    static let organ = InstrumentVoiceSpec(
        id: "organ", name: "Organ", family: "organ", engine: .subtractive,
        summary: "A sustained drawbar organ: the chord holds as long as the key does.",
        oscillators: [
            Oscillator(waveform: .sine, octave: 0, level: 1),
            Oscillator(waveform: .sine, octave: 1, level: 0.55),
            Oscillator(waveform: .sine, octave: 2, cents: 2, level: 0.3),
            Oscillator(waveform: .square, octave: 0, level: 0.18),
        ],
        subLevel: 0.4,
        filterHz: 6_000, filterKeyTrack: 0.3, filterQ: 0.7, filterEnvelopeOctaves: 0,
        amplitude: Envelope(attack: 0.006, decay: 0.05, sustain: 1, release: 0.08),
        drive: 0.2, level: 0.72, durationSeconds: 4)

    /// One square, wide open: the lead that sits on top of everything.
    static let squareLead = InstrumentVoiceSpec(
        id: "lead", name: "Square Lead", family: "lead", engine: .subtractive,
        summary: "A hollow square lead, for a tune on top.",
        oscillators: [
            Oscillator(waveform: .pulse, cents: 0, level: 1, pulseWidth: 0.3),
            Oscillator(waveform: .pulse, cents: 8, level: 0.55, pulseWidth: 0.42),
        ],
        subLevel: 0.2,
        filterHz: 2_600, filterKeyTrack: 0.7, filterQ: 1.6, filterEnvelopeOctaves: 1.2,
        filterEnvelope: Envelope(attack: 0.004, decay: 0.5, sustain: 0.5, release: 0.2),
        amplitude: Envelope(attack: 0.004, decay: 0.4, sustain: 0.85, release: 0.15),
        drive: 0.25, level: 0.78, durationSeconds: 4, velocityLayers: [55, 115])

    /// Brass: the filter swells into the note rather than snapping.
    static let brass = InstrumentVoiceSpec(
        id: "brass", name: "Brass", family: "brass", engine: .subtractive,
        summary: "Synth brass that opens up as the note plays.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -6, level: 1),
            Oscillator(waveform: .saw, cents: 7, level: 0.85),
        ],
        filterHz: 900, filterKeyTrack: 0.6, filterQ: 1.8, filterEnvelopeOctaves: 2.4,
        filterEnvelope: Envelope(attack: 0.09, decay: 0.7, sustain: 0.55, release: 0.3),
        amplitude: Envelope(attack: 0.035, decay: 0.6, sustain: 0.85, release: 0.25),
        drive: 0.2, level: 0.78, durationSeconds: 4, velocityLayers: [55, 115])
}
