import Foundation

// MARK: - The rest of the bank

// The presets past the first eleven, by family. Each is a generator the sampler plays, like the
// others: rendered once across the keyboard and cached, so a bank of fifty costs nothing until a
// part asks for one. None is a recording, and the acoustic ones are sketches of their instrument
// rather than copies of it — a sampled instrument comes in through an imported SFZ.

public extension InstrumentVoiceSpec {

    // MARK: Keys

    /// A grand piano, sketched in FM: two pairs, each a string of the unison, one tuned a hair
    /// sharp of the other so the note beats slowly the way three strings on a real note do. The
    /// modulators fall away faster than the carriers — a hammer's brightness goes first — and the
    /// second pair carries a high, fast knock for the hammer itself. Three layers, because on a
    /// piano how hard you play is mostly how bright it is. A sketch, not a sample: an imported
    /// SFZ grand is the real thing.
    static let grandPiano = InstrumentVoiceSpec(
        id: "grand-piano", name: "Grand Piano", family: "keys", engine: .fm,
        summary: "A bright, ringing grand piano for chords and ballads.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 4.2, sustain: 0.04),
            Operator(ratio: 1, level: 0.62, attack: 0.001, decay: 0.9, sustain: 0.06),
            Operator(ratio: 1.0014, level: 0.75, attack: 0.001, decay: 3.2, sustain: 0.03),
            Operator(ratio: 5.01, level: 0.24, attack: 0.001, decay: 0.05, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 4.5, sustain: 0.04, release: 0.35),
        drive: 0.04, level: 0.88, durationSeconds: 6, velocityLayers: [35, 80, 120])

    /// The eighties digital piano: a bright attack pair over a clean body, glassier than the Rhodes.
    static let fmPiano = InstrumentVoiceSpec(
        id: "fm-piano", name: "FM Piano", family: "keys", engine: .fm,
        summary: "A bright, glassy digital piano that stays clear in a busy mix.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 3.2, sustain: 0.08),
            Operator(ratio: 1, level: 0.5, attack: 0.001, decay: 0.9, sustain: 0.05),
            Operator(ratio: 2, level: 0.32, attack: 0.001, decay: 1.8, sustain: 0.05),
            Operator(ratio: 3, level: 0.42, attack: 0.001, decay: 0.22, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 3.4, sustain: 0.1, release: 0.3),
        drive: 0.05, level: 0.85, durationSeconds: 5, velocityLayers: [45, 110])

    /// A felted upright: a low index for the soft hammer, a sine an octave up for the body.
    static let feltPiano = InstrumentVoiceSpec(
        id: "felt-piano", name: "Felt Piano", family: "keys", engine: .fm,
        summary: "A soft, felted piano: intimate and muted, for quiet chords.",
        algorithm: .onePairTwoSines,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.003, decay: 2.8, sustain: 0.06),
            Operator(ratio: 1, level: 0.28, attack: 0.001, decay: 0.35, sustain: 0),
            Operator(ratio: 2.003, level: 0.22, attack: 0.002, decay: 1.4, sustain: 0),
            Operator(ratio: 3.01, level: 0.08, attack: 0.002, decay: 0.7, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.004, decay: 3, sustain: 0.05, release: 0.4),
        level: 0.9, durationSeconds: 5, velocityLayers: [45, 110])

    /// A clavinet: a string plucked right at the end, short and nasal.
    static let clavinet = InstrumentVoiceSpec(
        id: "clavinet", name: "Clavinet", family: "keys", engine: .pluckedString,
        summary: "Funky, percussive and nasal: the clavinet's bite.",
        pluck: Pluck(decaySeconds: 0.9, decayKeyTrack: 0.4, brightnessHz: 7_000, pickPosition: 0.06),
        filterHz: 3_200, filterKeyTrack: 0.6, filterQ: 1.8,
        amplitude: Envelope(attack: 0.001, decay: 1, sustain: 1, release: 0.06),
        drive: 0.2, level: 0.85, durationSeconds: 2.5, velocityLayers: [55, 115])

    /// Quills on strings: bright, jangly and quick to settle.
    static let harpsichord = InstrumentVoiceSpec(
        id: "harpsichord", name: "Harpsichord", family: "keys", engine: .pluckedString,
        summary: "Bright and plucked, with the jangle of a baroque keyboard.",
        pluck: Pluck(decaySeconds: 1.8, decayKeyTrack: 0.6, brightnessHz: 10_000, pickPosition: 0.1),
        amplitude: Envelope(attack: 0.001, decay: 2, sustain: 1, release: 0.2),
        level: 0.8, durationSeconds: 3.5)

    /// Little struck metal rods: inharmonic and short.
    static let toyPiano = InstrumentVoiceSpec(
        id: "toy-piano", name: "Toy Piano", family: "keys", engine: .fm,
        summary: "Tinny little metal bars: a toy piano's plink.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 1.1, sustain: 0),
            Operator(ratio: 3.95, level: 0.45, attack: 0.001, decay: 0.3, sustain: 0),
            Operator(ratio: 2, level: 0.3, attack: 0.001, decay: 0.6, sustain: 0),
            Operator(ratio: 7.1, level: 0.3, attack: 0.001, decay: 0.08, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 1.3, sustain: 0, release: 0.2),
        level: 0.75, durationSeconds: 2.5)

    // MARK: Organs

    /// Drawbars through an overdriven amp and a spinning speaker.
    static let rockOrgan = InstrumentVoiceSpec(
        id: "rock-organ", name: "Rock Organ", family: "organ", engine: .subtractive,
        summary: "A driven drawbar organ, with a spinning speaker's wobble.",
        vibrato: Modulation(rateHz: 6.6, depth: 10, delaySeconds: 0),
        tremolo: Modulation(rateHz: 6.6, depth: 0.18, delaySeconds: 0),
        oscillators: [
            Oscillator(waveform: .sine, level: 1),
            Oscillator(waveform: .sine, octave: 1, level: 0.7),
            Oscillator(waveform: .sine, octave: 2, level: 0.45),
            Oscillator(waveform: .square, level: 0.3),
        ],
        subLevel: 0.5,
        filterHz: 4_500, filterKeyTrack: 0.3, filterQ: 0.8,
        amplitude: Envelope(attack: 0.004, decay: 0.05, sustain: 1, release: 0.06),
        drive: 0.55, level: 0.7, durationSeconds: 4)

    /// Pipes at four footages: broad, still, slow to speak.
    static let pipeOrgan = InstrumentVoiceSpec(
        id: "pipe-organ", name: "Pipe Organ", family: "organ", engine: .subtractive,
        summary: "Stacked pipes: broad, still and churchly.",
        oscillators: [
            Oscillator(waveform: .sine, octave: -1, level: 0.6),
            Oscillator(waveform: .triangle, level: 1),
            Oscillator(waveform: .sine, octave: 1, level: 0.6),
            Oscillator(waveform: .sine, octave: 2, level: 0.3),
        ],
        noiseLevel: 0.01,
        filterHz: 5_000, filterKeyTrack: 0.3, filterQ: 0.7,
        amplitude: Envelope(attack: 0.08, decay: 0.2, sustain: 1, release: 0.45),
        level: 0.72, durationSeconds: 5)

    /// A pump organ: reeds, a narrow pulse, a little air.
    static let harmonium = InstrumentVoiceSpec(
        id: "harmonium", name: "Harmonium", family: "organ", engine: .subtractive,
        summary: "A reedy pump organ, warm and a little wheezy.",
        vibrato: Modulation(rateHz: 4.5, depth: 4, delaySeconds: 0.4),
        oscillators: [
            Oscillator(waveform: .pulse, level: 0.9, pulseWidth: 0.22),
            Oscillator(waveform: .saw, cents: 5, level: 0.5),
        ],
        noiseLevel: 0.025,
        filterHz: 1_600, filterKeyTrack: 0.5, filterQ: 1.1,
        amplitude: Envelope(attack: 0.07, decay: 0.2, sustain: 1, release: 0.25),
        level: 0.7, durationSeconds: 4)

    /// The sixties combo organ: thin, buzzy and bright.
    static let comboOrgan = InstrumentVoiceSpec(
        id: "combo-organ", name: "Combo Organ", family: "organ", engine: .subtractive,
        summary: "The thin, buzzy sixties combo organ.",
        vibrato: Modulation(rateHz: 6, depth: 8, delaySeconds: 0),
        oscillators: [
            Oscillator(waveform: .square, level: 0.8),
            Oscillator(waveform: .pulse, octave: 1, level: 0.4, pulseWidth: 0.25),
        ],
        filterHz: 3_000, filterKeyTrack: 0.5, filterQ: 1,
        amplitude: Envelope(attack: 0.003, decay: 0.05, sustain: 1, release: 0.05),
        drive: 0.15, level: 0.65, durationSeconds: 4)

    // MARK: Mallets and bells

    /// Warm metal bars, the fan motor turning.
    static let vibraphone = InstrumentVoiceSpec(
        id: "vibraphone", name: "Vibraphone", family: "bell", engine: .fm,
        summary: "Warm metal bars with the vibes' slow shimmer.",
        tremolo: Modulation(rateHz: 5.2, depth: 0.35, delaySeconds: 0.15),
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 3.6, sustain: 0),
            Operator(ratio: 4, level: 0.22, attack: 0.001, decay: 0.3, sustain: 0),
            Operator(ratio: 1, level: 0.25, attack: 0.001, decay: 2.2, sustain: 0),
            Operator(ratio: 10, level: 0.12, attack: 0.001, decay: 0.05, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 4, sustain: 0, release: 0.5),
        level: 0.8, durationSeconds: 5, velocityLayers: [45, 110])

    /// Hard mallets on rosewood: brighter and drier than the marimba.
    static let xylophone = InstrumentVoiceSpec(
        id: "xylophone", name: "Xylophone", family: "bell", engine: .fm,
        summary: "Hard mallets on wood: bright, dry and quick.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 0.4, sustain: 0),
            Operator(ratio: 3, level: 0.55, attack: 0.001, decay: 0.08, sustain: 0),
            Operator(ratio: 3, level: 0.25, attack: 0.001, decay: 0.25, sustain: 0),
            Operator(ratio: 11, level: 0.25, attack: 0.001, decay: 0.03, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 0.5, sustain: 0, release: 0.15),
        level: 0.85, durationSeconds: 1.5)

    /// Small steel bars: the partials sit high and ring clear.
    static let glockenspiel = InstrumentVoiceSpec(
        id: "glockenspiel", name: "Glockenspiel", family: "bell", engine: .fm,
        summary: "Bright, tiny steel bars that ring clear and high.",
        algorithm: .onePairTwoSines,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 2.6, sustain: 0),
            Operator(ratio: 2.76, level: 0.25, attack: 0.001, decay: 0.4, sustain: 0),
            Operator(ratio: 5.4, level: 0.18, attack: 0.001, decay: 0.9, sustain: 0),
            Operator(ratio: 8.93, level: 0.08, attack: 0.001, decay: 0.3, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 2.8, sustain: 0, release: 0.4),
        level: 0.7, durationSeconds: 3.5)

    /// A thumb piano: a tine in a box, soft and woody.
    static let kalimba = InstrumentVoiceSpec(
        id: "kalimba", name: "Kalimba", family: "bell", engine: .fm,
        summary: "A thumb piano: soft, woody plinks with a short ring.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 1, sustain: 0),
            Operator(ratio: 5.9, level: 0.3, attack: 0.001, decay: 0.07, sustain: 0),
            Operator(ratio: 1, level: 0.2, attack: 0.001, decay: 0.5, sustain: 0),
            Operator(ratio: 1, level: 0, attack: 0.001, decay: 0.1, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 1.1, sustain: 0, release: 0.2),
        level: 0.85, durationSeconds: 2)

    /// A steel pan: a hammered dome, round and singing.
    static let steelDrum = InstrumentVoiceSpec(
        id: "steel-drum", name: "Steel Drum", family: "bell", engine: .fm,
        summary: "Caribbean steel pan: bright, round and singing.",
        algorithm: .onePairTwoSines,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.002, decay: 1.4, sustain: 0),
            Operator(ratio: 2, level: 0.55, attack: 0.001, decay: 0.35, sustain: 0),
            Operator(ratio: 2.02, level: 0.3, attack: 0.002, decay: 1, sustain: 0),
            Operator(ratio: 3.98, level: 0.12, attack: 0.002, decay: 0.5, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.002, decay: 1.6, sustain: 0, release: 0.25),
        level: 0.8, durationSeconds: 2.5, velocityLayers: [50, 112])

    /// A wind-up comb: delicate, high and quickly gone.
    static let musicBox = InstrumentVoiceSpec(
        id: "music-box", name: "Music Box", family: "bell", engine: .fm,
        summary: "A wind-up music box: delicate, high and bell-clear.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 1.8, sustain: 0),
            Operator(ratio: 5.5, level: 0.2, attack: 0.001, decay: 0.2, sustain: 0),
            Operator(ratio: 4, level: 0.15, attack: 0.001, decay: 1, sustain: 0),
            Operator(ratio: 11, level: 0.2, attack: 0.001, decay: 0.05, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 2, sustain: 0, release: 0.3),
        level: 0.7, durationSeconds: 3)

    /// Orchestral chimes: long, inharmonic, ringing on.
    static let tubularBells = InstrumentVoiceSpec(
        id: "tubular-bells", name: "Tubular Bells", family: "bell", engine: .fm,
        summary: "Big orchestral chimes that ring on and on.",
        algorithm: .onePairTwoSines,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 6, sustain: 0),
            Operator(ratio: 2.76, level: 0.3, attack: 0.001, decay: 1.2, sustain: 0),
            Operator(ratio: 2.76, level: 0.25, attack: 0.001, decay: 4, sustain: 0),
            Operator(ratio: 5.4, level: 0.15, attack: 0.001, decay: 2.5, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 6.5, sustain: 0, release: 0.8),
        level: 0.7, durationSeconds: 7)

    // MARK: Plucked strings

    static let nylonGuitar = InstrumentVoiceSpec(
        id: "nylon-guitar", name: "Nylon Guitar", family: "plucked", engine: .pluckedString,
        summary: "A classical guitar: warm, round and gently plucked.",
        pluck: Pluck(decaySeconds: 2.2, decayKeyTrack: 0.5, brightnessHz: 2_600, pickPosition: 0.22),
        filterHz: 4_000, filterKeyTrack: 0.5, filterQ: 0.8,
        amplitude: Envelope(attack: 0.001, decay: 2.5, sustain: 1, release: 0.25),
        level: 0.9, durationSeconds: 4, velocityLayers: [50, 112])

    static let steelGuitar = InstrumentVoiceSpec(
        id: "steel-guitar", name: "Steel Guitar", family: "plucked", engine: .pluckedString,
        summary: "An acoustic steel-string: bright, ringing and full.",
        pluck: Pluck(decaySeconds: 3, decayKeyTrack: 0.5, brightnessHz: 6_500, pickPosition: 0.14),
        amplitude: Envelope(attack: 0.001, decay: 3, sustain: 1, release: 0.3),
        level: 0.85, durationSeconds: 4.5, velocityLayers: [50, 112])

    static let cleanElectric = InstrumentVoiceSpec(
        id: "clean-electric", name: "Clean Electric", family: "plucked", engine: .pluckedString,
        summary: "A clean electric guitar, with a touch of amp warmth.",
        pluck: Pluck(decaySeconds: 2.6, decayKeyTrack: 0.4, brightnessHz: 4_500, pickPosition: 0.1),
        filterHz: 5_000, filterKeyTrack: 0.4, filterQ: 1.2,
        amplitude: Envelope(attack: 0.001, decay: 3, sustain: 1, release: 0.25),
        drive: 0.25, level: 0.85, durationSeconds: 4, velocityLayers: [50, 112])

    /// An electric through a pushed amp: the string driven into saturation, which squashes its
    /// decay into sustain, then darkened the way a guitar speaker cuts everything over 4 kHz. Each
    /// note is driven on its own and chords are summed after, so a chord is cleaner than a real
    /// amp makes it — fine for single lines and power chords, polite on a full barre chord.
    static let overdrivenGuitar = InstrumentVoiceSpec(
        id: "overdrive-guitar", name: "Overdriven Guitar", family: "plucked", engine: .pluckedString,
        summary: "An electric through a cranked amp: warm, singing overdrive for riffs and leads.",
        pluck: Pluck(decaySeconds: 4, decayKeyTrack: 0.3, brightnessHz: 5_000, pickPosition: 0.11),
        filterHz: 3_200, filterKeyTrack: 0.2, filterQ: 1.5,
        amplitude: Envelope(attack: 0.001, decay: 4, sustain: 1, release: 0.18),
        drive: 0.8, level: 0.72, durationSeconds: 4.5, velocityLayers: [50, 112])

    /// Harder again: more drive, a darker speaker, less dynamics left.
    static let distortedGuitar = InstrumentVoiceSpec(
        id: "distorted-guitar", name: "Distorted Guitar", family: "plucked", engine: .pluckedString,
        summary: "High-gain distortion: thick, compressed and aggressive, for power chords and rock riffs.",
        pluck: Pluck(decaySeconds: 5, decayKeyTrack: 0.2, brightnessHz: 5_500, pickPosition: 0.1),
        filterHz: 2_600, filterKeyTrack: 0.15, filterQ: 1.8,
        amplitude: Envelope(attack: 0.001, decay: 5, sustain: 1, release: 0.15),
        drive: 1, level: 0.66, durationSeconds: 5, velocityLayers: [50, 112])

    static let mutedGuitar = InstrumentVoiceSpec(
        id: "muted-guitar", name: "Muted Guitar", family: "plucked", engine: .pluckedString,
        summary: "Palm-muted plucks: short, tight and rhythmic.",
        pluck: Pluck(decaySeconds: 0.35, decayKeyTrack: 0.3, brightnessHz: 2_000, pickPosition: 0.15),
        filterHz: 1_800, filterKeyTrack: 0.5, filterQ: 0.9,
        amplitude: Envelope(attack: 0.001, decay: 0.5, sustain: 1, release: 0.05),
        drive: 0.1, level: 0.9, durationSeconds: 1.5, velocityLayers: [50, 112])

    static let harp = InstrumentVoiceSpec(
        id: "harp", name: "Harp", family: "plucked", engine: .pluckedString,
        summary: "Concert harp: soft, round plucks that ring long.",
        pluck: Pluck(decaySeconds: 3.5, decayKeyTrack: 0.6, brightnessHz: 3_000, pickPosition: 0.3),
        amplitude: Envelope(attack: 0.001, decay: 3.5, sustain: 1, release: 0.5),
        level: 0.85, durationSeconds: 5)

    static let koto = InstrumentVoiceSpec(
        id: "koto", name: "Koto", family: "plucked", engine: .pluckedString,
        summary: "The Japanese koto: bright, twangy and poised.",
        pluck: Pluck(decaySeconds: 1.6, decayKeyTrack: 0.4, brightnessHz: 5_000, pickPosition: 0.08),
        filterHz: 5_500, filterKeyTrack: 0.5, filterQ: 1.6,
        amplitude: Envelope(attack: 0.001, decay: 2, sustain: 1, release: 0.25),
        level: 0.85, durationSeconds: 3)

    static let banjo = InstrumentVoiceSpec(
        id: "banjo", name: "Banjo", family: "plucked", engine: .pluckedString,
        summary: "Bright and twangy, with a banjo's quick decay.",
        pluck: Pluck(decaySeconds: 0.9, decayKeyTrack: 0.3, brightnessHz: 8_000, pickPosition: 0.06),
        amplitude: Envelope(attack: 0.001, decay: 1, sustain: 1, release: 0.12),
        drive: 0.1, level: 0.8, durationSeconds: 2)

    static let pizzicato = InstrumentVoiceSpec(
        id: "pizzicato", name: "Pizzicato", family: "plucked", engine: .pluckedString,
        summary: "Plucked orchestral strings: short, woody and light.",
        pluck: Pluck(decaySeconds: 0.45, decayKeyTrack: 0.3, brightnessHz: 1_800, pickPosition: 0.35),
        filterHz: 2_500, filterKeyTrack: 0.6, filterQ: 0.8,
        amplitude: Envelope(attack: 0.001, decay: 0.6, sustain: 1, release: 0.1),
        level: 0.9, durationSeconds: 1.5)

    // MARK: Bowed strings

    static let stringSection = InstrumentVoiceSpec(
        id: "strings", name: "String Section", family: "strings", engine: .subtractive,
        summary: "A lush string section, bowed and warm.",
        vibrato: Modulation(rateHz: 5.2, depth: 9, delaySeconds: 0.5),
        oscillators: [
            Oscillator(waveform: .saw, cents: -9, level: 0.8),
            Oscillator(waveform: .saw, cents: 8, level: 0.8),
            Oscillator(waveform: .saw, octave: -1, cents: 3, level: 0.35),
        ],
        noiseLevel: 0.01,
        filterHz: 2_400, filterKeyTrack: 0.6, filterQ: 0.8, filterEnvelopeOctaves: 0.5,
        filterEnvelope: Envelope(attack: 0.3, decay: 1, sustain: 0.6, release: 0.6),
        amplitude: Envelope(attack: 0.25, decay: 0.8, sustain: 0.9, release: 0.6),
        level: 0.7, durationSeconds: 5)

    static let slowStrings = InstrumentVoiceSpec(
        id: "slow-strings", name: "Slow Strings", family: "strings", engine: .subtractive,
        summary: "Strings that swell in slowly, for long held chords.",
        vibrato: Modulation(rateHz: 5, depth: 8, delaySeconds: 0.9),
        oscillators: [
            Oscillator(waveform: .saw, cents: -10, level: 0.8),
            Oscillator(waveform: .saw, cents: 9, level: 0.8),
            Oscillator(waveform: .triangle, octave: -1, level: 0.4),
        ],
        filterHz: 1_600, filterKeyTrack: 0.6, filterQ: 0.8, filterEnvelopeOctaves: 0.8,
        filterEnvelope: Envelope(attack: 1, decay: 1.5, sustain: 0.6, release: 1),
        amplitude: Envelope(attack: 0.9, decay: 1.2, sustain: 0.9, release: 1.2),
        level: 0.7, durationSeconds: 6)

    static let violin = InstrumentVoiceSpec(
        id: "violin", name: "Solo Violin", family: "strings", engine: .subtractive,
        summary: "A single violin line, bright and singing, with vibrato.",
        vibrato: Modulation(rateHz: 6, depth: 20, delaySeconds: 0.3),
        oscillators: [
            Oscillator(waveform: .saw, level: 1),
            Oscillator(waveform: .pulse, cents: 3, level: 0.3, pulseWidth: 0.3),
        ],
        noiseLevel: 0.015,
        filterHz: 2_800, filterKeyTrack: 0.7, filterQ: 1.6,
        amplitude: Envelope(attack: 0.08, decay: 0.5, sustain: 0.9, release: 0.25),
        level: 0.72, durationSeconds: 4)

    static let cello = InstrumentVoiceSpec(
        id: "cello", name: "Solo Cello", family: "strings", engine: .subtractive,
        summary: "A single bowed low string: dark, singing and expressive.",
        vibrato: Modulation(rateHz: 5.5, depth: 18, delaySeconds: 0.35),
        oscillators: [
            Oscillator(waveform: .saw, level: 1),
            Oscillator(waveform: .pulse, level: 0.35, pulseWidth: 0.45),
        ],
        noiseLevel: 0.012,
        filterHz: 1_100, filterKeyTrack: 0.6, filterQ: 1.4,
        amplitude: Envelope(attack: 0.12, decay: 0.6, sustain: 0.9, release: 0.3),
        level: 0.75, durationSeconds: 4)

    // MARK: Pads and voices

    static let vocalOohs = InstrumentVoiceSpec(
        id: "oohs", name: "Vocal Oohs", family: "pad", engine: .subtractive,
        summary: "Soft 'ooh' voices, rounder than the choir.",
        vibrato: Modulation(rateHz: 5, depth: 6, delaySeconds: 0.5),
        oscillators: [
            Oscillator(waveform: .triangle, cents: -6, level: 0.9),
            Oscillator(waveform: .triangle, cents: 6, level: 0.9),
            Oscillator(waveform: .sine, octave: -1, level: 0.3),
        ],
        noiseLevel: 0.03,
        filterHz: 800, filterKeyTrack: 0.8, filterQ: 3,
        amplitude: Envelope(attack: 0.35, decay: 1, sustain: 0.85, release: 0.8),
        level: 0.75, durationSeconds: 5)

    static let glassPad = InstrumentVoiceSpec(
        id: "glass-pad", name: "Glass Pad", family: "pad", engine: .fm,
        summary: "A shimmering, crystalline pad with a glassy edge.",
        algorithm: .onePairTwoSines,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.8, decay: 3, sustain: 0.7),
            Operator(ratio: 3, level: 0.2, attack: 1.2, decay: 3, sustain: 0.5),
            Operator(ratio: 2.005, level: 0.35, attack: 1, decay: 3, sustain: 0.6),
            Operator(ratio: 5.01, level: 0.12, attack: 1.4, decay: 3, sustain: 0.4),
        ],
        amplitude: Envelope(attack: 0.8, decay: 2, sustain: 0.8, release: 1.4),
        level: 0.7, durationSeconds: 6)

    static let darkPad = InstrumentVoiceSpec(
        id: "dark-pad", name: "Dark Pad", family: "pad", engine: .subtractive,
        summary: "A low, murky pad for tension and space.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -12, level: 0.8),
            Oscillator(waveform: .saw, cents: 11, level: 0.8),
        ],
        subLevel: 0.5,
        filterHz: 380, filterKeyTrack: 0.45, filterQ: 1.2, filterEnvelopeOctaves: 0.6,
        filterEnvelope: Envelope(attack: 1.5, decay: 2, sustain: 0.5, release: 1),
        amplitude: Envelope(attack: 1.2, decay: 1.5, sustain: 0.85, release: 1.4),
        level: 0.8, durationSeconds: 6)

    static let airPad = InstrumentVoiceSpec(
        id: "air-pad", name: "Air Pad", family: "pad", engine: .subtractive,
        summary: "Breathy and bright, like wind behind the chords.",
        oscillators: [
            Oscillator(waveform: .triangle, cents: -5, level: 0.7),
            Oscillator(waveform: .sine, octave: 1, cents: 4, level: 0.4),
        ],
        noiseLevel: 0.15,
        filterHz: 3_500, filterKeyTrack: 0.5, filterQ: 1,
        amplitude: Envelope(attack: 1, decay: 1.5, sustain: 0.8, release: 1.4),
        level: 0.65, durationSeconds: 6)

    static let sweepPad = InstrumentVoiceSpec(
        id: "sweep-pad", name: "Sweep Pad", family: "pad", engine: .subtractive,
        summary: "A pad whose filter sweeps open over a few seconds.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -8, level: 0.8),
            Oscillator(waveform: .saw, cents: 8, level: 0.8),
            Oscillator(waveform: .pulse, octave: -1, level: 0.3, pulseWidth: 0.4),
        ],
        filterHz: 300, filterKeyTrack: 0.5, filterQ: 2.2, filterEnvelopeOctaves: 3,
        filterEnvelope: Envelope(attack: 2.5, decay: 3, sustain: 0.4, release: 1.5),
        amplitude: Envelope(attack: 0.4, decay: 2, sustain: 0.85, release: 1.5),
        level: 0.7, durationSeconds: 6)

    // MARK: Winds

    static let flute = InstrumentVoiceSpec(
        id: "flute", name: "Flute", family: "wind", engine: .subtractive,
        summary: "A breathy flute, soft and airy.",
        vibrato: Modulation(rateHz: 5, depth: 10, delaySeconds: 0.3),
        oscillators: [
            Oscillator(waveform: .sine, level: 1),
            Oscillator(waveform: .triangle, octave: 1, level: 0.12),
        ],
        noiseLevel: 0.06,
        filterHz: 3_000, filterKeyTrack: 0.6, filterQ: 0.8,
        amplitude: Envelope(attack: 0.06, decay: 0.4, sustain: 0.9, release: 0.18),
        level: 0.8, durationSeconds: 4)

    static let clarinet = InstrumentVoiceSpec(
        id: "clarinet", name: "Clarinet", family: "wind", engine: .subtractive,
        summary: "A woody, hollow clarinet with a round low end.",
        vibrato: Modulation(rateHz: 5, depth: 5, delaySeconds: 0.4),
        oscillators: [
            Oscillator(waveform: .square, level: 1),
            Oscillator(waveform: .triangle, level: 0.4),
        ],
        noiseLevel: 0.02,
        filterHz: 1_800, filterKeyTrack: 0.6, filterQ: 0.9,
        amplitude: Envelope(attack: 0.04, decay: 0.4, sustain: 0.9, release: 0.15),
        level: 0.7, durationSeconds: 4)

    static let oboe = InstrumentVoiceSpec(
        id: "oboe", name: "Oboe", family: "wind", engine: .subtractive,
        summary: "A nasal, plaintive oboe line.",
        vibrato: Modulation(rateHz: 5.5, depth: 12, delaySeconds: 0.3),
        oscillators: [
            Oscillator(waveform: .pulse, level: 1, pulseWidth: 0.15),
            Oscillator(waveform: .saw, level: 0.2),
        ],
        noiseLevel: 0.015,
        filterHz: 2_200, filterKeyTrack: 0.6, filterQ: 2,
        amplitude: Envelope(attack: 0.05, decay: 0.4, sustain: 0.9, release: 0.15),
        level: 0.68, durationSeconds: 4)

    /// A saxophone is a conical reed: a saw's full set of harmonics through a formant-ish
    /// low-pass that opens with how hard it is blown, breath under it, a bark at the front of the
    /// note from the filter envelope, and growl from the drive. The vibrato arrives late, as a
    /// player's does.
    static let tenorSax = InstrumentVoiceSpec(
        id: "tenor-sax", name: "Tenor Sax", family: "wind", engine: .subtractive,
        summary: "A husky, breathy tenor sax: warm in the low register, a growl when pushed.",
        vibrato: Modulation(rateHz: 5.2, depth: 14, delaySeconds: 0.35),
        oscillators: [
            Oscillator(waveform: .saw, level: 1),
            Oscillator(waveform: .square, cents: 3, level: 0.35),
        ],
        noiseLevel: 0.05,
        filterHz: 1_300, filterKeyTrack: 0.5, filterQ: 1.6, filterEnvelopeOctaves: 1.2,
        filterEnvelope: Envelope(attack: 0.03, decay: 0.25, sustain: 0.6, release: 0.15),
        amplitude: Envelope(attack: 0.035, decay: 0.4, sustain: 0.88, release: 0.14),
        drive: 0.35, level: 0.7, durationSeconds: 4, velocityLayers: [55, 115])

    /// The alto: brighter and more nasal, a little less air.
    static let altoSax = InstrumentVoiceSpec(
        id: "alto-sax", name: "Alto Sax", family: "wind", engine: .subtractive,
        summary: "A bright, singing alto sax for melodies and solos.",
        vibrato: Modulation(rateHz: 5.5, depth: 12, delaySeconds: 0.3),
        oscillators: [
            Oscillator(waveform: .saw, level: 1),
            Oscillator(waveform: .pulse, level: 0.3, pulseWidth: 0.35),
        ],
        noiseLevel: 0.035,
        filterHz: 1_900, filterKeyTrack: 0.5, filterQ: 1.8, filterEnvelopeOctaves: 1,
        filterEnvelope: Envelope(attack: 0.025, decay: 0.22, sustain: 0.65, release: 0.14),
        amplitude: Envelope(attack: 0.03, decay: 0.4, sustain: 0.88, release: 0.13),
        drive: 0.28, level: 0.68, durationSeconds: 4, velocityLayers: [55, 115])

    static let panFlute = InstrumentVoiceSpec(
        id: "pan-flute", name: "Pan Flute", family: "wind", engine: .subtractive,
        summary: "Breathy pipes, with the chiff of air across them.",
        vibrato: Modulation(rateHz: 4.5, depth: 6, delaySeconds: 0.4),
        oscillators: [
            Oscillator(waveform: .sine, level: 1),
            Oscillator(waveform: .sine, octave: 1, level: 0.08),
        ],
        noiseLevel: 0.12,
        filterHz: 2_500, filterKeyTrack: 0.6, filterQ: 1.2, filterEnvelopeOctaves: 1,
        filterEnvelope: Envelope(attack: 0.001, decay: 0.08, sustain: 0.2, release: 0.1),
        amplitude: Envelope(attack: 0.08, decay: 0.5, sustain: 0.8, release: 0.25),
        level: 0.8, durationSeconds: 4)

    // MARK: Brass

    static let synthBrass = InstrumentVoiceSpec(
        id: "synth-brass", name: "Synth Brass", family: "brass", engine: .subtractive,
        summary: "Punchy eighties synth brass for stabs and riffs.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -8, level: 1),
            Oscillator(waveform: .saw, cents: 8, level: 1),
            Oscillator(waveform: .square, octave: -1, level: 0.3),
        ],
        filterHz: 700, filterKeyTrack: 0.6, filterQ: 1.4, filterEnvelopeOctaves: 2.8,
        filterEnvelope: Envelope(attack: 0.03, decay: 0.35, sustain: 0.45, release: 0.2),
        amplitude: Envelope(attack: 0.012, decay: 0.4, sustain: 0.8, release: 0.2),
        drive: 0.25, level: 0.75, durationSeconds: 3, velocityLayers: [55, 115])

    static let trumpet = InstrumentVoiceSpec(
        id: "trumpet", name: "Trumpet", family: "brass", engine: .subtractive,
        summary: "A bright solo trumpet with a brassy bite.",
        vibrato: Modulation(rateHz: 5.5, depth: 10, delaySeconds: 0.35),
        oscillators: [
            Oscillator(waveform: .saw, level: 1),
            Oscillator(waveform: .pulse, level: 0.3, pulseWidth: 0.3),
        ],
        filterHz: 1_200, filterKeyTrack: 0.7, filterQ: 1.2, filterEnvelopeOctaves: 1.8,
        filterEnvelope: Envelope(attack: 0.05, decay: 0.4, sustain: 0.7, release: 0.2),
        amplitude: Envelope(attack: 0.04, decay: 0.4, sustain: 0.9, release: 0.18),
        drive: 0.2, level: 0.72, durationSeconds: 4, velocityLayers: [55, 115])

    static let frenchHorns = InstrumentVoiceSpec(
        id: "horns", name: "French Horns", family: "brass", engine: .subtractive,
        summary: "Mellow horns: round and noble, a pad made of brass.",
        vibrato: Modulation(rateHz: 5, depth: 5, delaySeconds: 0.5),
        oscillators: [
            Oscillator(waveform: .saw, cents: -4, level: 0.8),
            Oscillator(waveform: .triangle, cents: 4, level: 0.7),
        ],
        filterHz: 700, filterKeyTrack: 0.6, filterQ: 1, filterEnvelopeOctaves: 0.8,
        filterEnvelope: Envelope(attack: 0.15, decay: 0.6, sustain: 0.6, release: 0.4),
        amplitude: Envelope(attack: 0.12, decay: 0.6, sustain: 0.9, release: 0.35),
        level: 0.75, durationSeconds: 4)

    // MARK: Synth plucks

    static let bellPluck = InstrumentVoiceSpec(
        id: "bell-pluck", name: "Bell Pluck", family: "pluck", engine: .fm,
        summary: "A plucked bell-synth for sparkling arpeggios.",
        algorithm: .twinPairs,
        operators: [
            Operator(ratio: 1, level: 1, attack: 0.001, decay: 0.6, sustain: 0),
            Operator(ratio: 3.5, level: 0.35, attack: 0.001, decay: 0.15, sustain: 0),
            Operator(ratio: 2, level: 0.35, attack: 0.001, decay: 0.4, sustain: 0),
            Operator(ratio: 7, level: 0.2, attack: 0.001, decay: 0.05, sustain: 0),
        ],
        amplitude: Envelope(attack: 0.001, decay: 0.7, sustain: 0, release: 0.15),
        level: 0.8, durationSeconds: 1.5, velocityLayers: [50, 112])

    static let houseStab = InstrumentVoiceSpec(
        id: "stab", name: "House Stab", family: "pluck", engine: .subtractive,
        summary: "A short, punchy chord stab.",
        oscillators: [
            Oscillator(waveform: .saw, cents: -10, level: 0.9),
            Oscillator(waveform: .saw, cents: 10, level: 0.9),
            Oscillator(waveform: .square, octave: 1, level: 0.3),
        ],
        filterHz: 900, filterKeyTrack: 0.6, filterQ: 2, filterEnvelopeOctaves: 2.6,
        filterEnvelope: Envelope(attack: 0.001, decay: 0.2, sustain: 0.1, release: 0.1),
        amplitude: Envelope(attack: 0.001, decay: 0.35, sustain: 0.1, release: 0.1),
        drive: 0.3, level: 0.8, durationSeconds: 1.5, velocityLayers: [55, 115])

    // MARK: Leads

    static let sawLead = InstrumentVoiceSpec(
        id: "saw-lead", name: "Saw Lead", family: "lead", engine: .subtractive,
        summary: "A bright, buzzing saw lead that cuts through.",
        vibrato: Modulation(rateHz: 6, depth: 12, delaySeconds: 0.4),
        oscillators: [
            Oscillator(waveform: .saw, cents: -5, level: 1),
            Oscillator(waveform: .saw, cents: 5, level: 0.8),
        ],
        subLevel: 0.2,
        filterHz: 3_500, filterKeyTrack: 0.6, filterQ: 1.2,
        amplitude: Envelope(attack: 0.004, decay: 0.3, sustain: 0.9, release: 0.12),
        drive: 0.2, level: 0.72, durationSeconds: 4)

    static let sineLead = InstrumentVoiceSpec(
        id: "sine-lead", name: "Sine Lead", family: "lead", engine: .subtractive,
        summary: "A pure, whistling lead, smooth as a theremin.",
        vibrato: Modulation(rateHz: 5.5, depth: 15, delaySeconds: 0.25),
        oscillators: [
            Oscillator(waveform: .sine, level: 1),
            Oscillator(waveform: .triangle, level: 0.15),
        ],
        amplitude: Envelope(attack: 0.02, decay: 0.3, sustain: 0.95, release: 0.2),
        level: 0.85, durationSeconds: 4)

    // MARK: Chip

    static let chipSquare = InstrumentVoiceSpec(
        id: "chip-square", name: "Chip Square", family: "chip", engine: .subtractive,
        summary: "An 8-bit square, straight out of an old game console.",
        oscillators: [Oscillator(waveform: .square, level: 1)],
        amplitude: Envelope(attack: 0.001, decay: 0.1, sustain: 0.8, release: 0.04),
        level: 0.6, durationSeconds: 3)

    static let chipPulse = InstrumentVoiceSpec(
        id: "chip-pulse", name: "Chip Pulse", family: "chip", engine: .subtractive,
        summary: "A thin, nasal 8-bit pulse.",
        oscillators: [Oscillator(waveform: .pulse, level: 1, pulseWidth: 0.125)],
        amplitude: Envelope(attack: 0.001, decay: 0.1, sustain: 0.8, release: 0.04),
        level: 0.6, durationSeconds: 3)

    static let chipTriangle = InstrumentVoiceSpec(
        id: "chip-triangle", name: "Chip Triangle", family: "chip", engine: .subtractive,
        summary: "The soft 8-bit triangle, for bass lines and tunes alike.",
        oscillators: [Oscillator(waveform: .triangle, level: 1)],
        amplitude: Envelope(attack: 0.001, decay: 0.1, sustain: 0.9, release: 0.04),
        level: 0.8, durationSeconds: 3)
}
