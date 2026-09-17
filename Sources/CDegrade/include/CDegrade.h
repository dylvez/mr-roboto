// The degradation chain (M1 task A4): bit and sample-rate reduction, saturation, tape wow and
// flutter, medium noise, and a high-frequency rolloff — the stage that turns a clean sample into
// something that sounds like it came off a record.
//
// In C11 for the same reason as the render core: macOS 27 marks
// `AVAudioSourceNodeRenderBlockRealtimeSafe` `__SWIFT_UNAVAILABLE_MSG("Swift is not supported for
// use with audio realtime threads")`, so anything that has to run inside a render block lives here
// and Swift owns every allocation and every lifetime. The same object is used offline, where the
// only thing that changes is who calls `dg_process`.
//
// Thread model (two roles, and only these):
//   * owner thread — dg_create / dg_destroy / dg_reset / dg_set_params. One thread at a time.
//                    dg_set_params and dg_reset are documented below for concurrent use.
//   * audio thread — dg_process, and nothing else.
//
// dg_process allocates nothing, takes no lock, touches no file, reads no clock, and calls nothing
// from Objective-C or Swift. It is deterministic: every random number comes from a 64-bit PRNG
// seeded from `dg_params_t.seed` and carried in the state, never from `rand()` or the time of day.
// Two runs over the same input from the same starting state are byte-identical, which is what the
// offline-bounce guarantee rests on.
//
// Audio is planar float throughout: `channels[c]` points at a buffer of samples for channel `c`.
//
//
// MARK: - What is being modelled, and where the numbers come from
//
// E-mu SP-1200 (1987). 12-bit, 26.04 kHz, and a deliberately absent reconstruction filter.
//   * "26.04 kHz 12-bit samples"; "A reconstruction filter was deliberately omitted, resulting in
//     a brighter sound due to imaging"; the machine's drop-sample pitch shifting produces
//     "significant additional (unfiltered) audible artifacts and distortion which proved to be
//     musically useful". Filtering after the DAC is analog: SSM2044 on some channel pairs, none at
//     all on channels 7-8. — https://en.wikipedia.org/wiki/E-mu_SP-1200
//   * Rossum (Dave Rossum designed the original) states the reissue keeps a "12-bit linear data
//     format" at a "26.04 kHz sampling rate", and that "the unmistakable character of SP-1200's
//     authentic, original pitch shifting and its audible aliasing and imaging artifacts are
//     preserved identically". — https://www.rossum-electro.com/products/sp-1200
//   * Verified: 26.04 kHz is the real figure and not folklore, and it is *linear* 12-bit, not
//     companded. What was NOT verified from a primary source: the exact converter part numbers and
//     the derivation of 26.04 kHz from the machine's master clock. Treat those as unknown.
//   So "12-bit crunch" here is four separate things, and this chain models each one separately:
//     1. quantisation to 2^12 codes — a noise floor that is correlated with the signal rather than
//        a smooth hiss, which is what makes it sound like grit rather than tape;
//     2. the low sample rate — a 13.02 kHz ceiling, so cymbals lose their air;
//     3. aliasing — anything above 13.02 kHz that reaches the converter folds down into the band,
//        and on the real machine the drop-sample pitch shifter reintroduced exactly that;
//     4. imaging — with no reconstruction filter the zero-order hold's spectral images survive
//        above 13.02 kHz, which is the "brighter" half of the SP-1200's reputation.
//   Companding is a fifth ingredient on other machines but not on this one (see MPC60).
//
// Akai MPC60 (1988) and MPC3000 (1994). Same era, different character.
//   * MPC60: "12 bit non-linear sampling at 40 kHz"; the non-linear (companded) format is
//     described as "quieter than 12 bit linear", and the machine's quoted response is about
//     18 kHz. — https://www.vintagesynth.com/akai/mpc60,
//     https://www.soundonsound.com/music-business/akai-mpc60-revisited ("26.2 seconds of sampling
//     at 12-bit and 40kHz")
//   * MPC3000: 16-bit, 44.1 kHz linear, with a 12 dB/octave resonant lowpass added.
//     — https://www.musicradar.com/news/vintage-music-tech-icons-akai-mpc3000
//   How they differ from the SP-1200: 40 kHz buys a 20 kHz Nyquist instead of 13.02 kHz, so the
//   MPC60 keeps its top end and reads as punchy and clean where the SP-1200 reads as dark and
//   gritty; and because the 12 bits are companded rather than linear, the quantisation floor is
//   proportional to the signal instead of fixed, so quiet passages stay quiet. That is why an
//   MPC60 chop sounds "thick" and an SP-1200 chop sounds "dirty". The MPC3000 is essentially
//   transparent by these standards and is not given a preset here.
//   Not verified: the exact companding law Akai used. `companding` below is a mu-law approximation
//   and is labelled as such.
//
// Tape.
//   * Wow and flutter are one phenomenon split at 4 Hz: speed variation below ~4 Hz is wow (once
//     per revolution of a capstan, reel or record), above it is flutter. "Listeners find flutter
//     most objectionable when the actual frequency of wobble is 4 Hz", which is why the weighting
//     curve peaks there, and measurement uses a 3.15 kHz tone.
//     — https://en.wikipedia.org/wiki/Wow_and_flutter_measurement
//   * Magnitudes: professional reel-to-reel is "around 0.02%, which is considered inaudible";
//     high-end cassette decks are "around 0.08% weighted, which is still audible under some
//     conditions" (same source). Hi-fi cassette decks are specified no worse than +/-0.2% and
//     non-hi-fi within +/-0.4%; a typical modern cassette recorder specifies 0.08%.
//     — https://en.wikipedia.org/wiki/Audio_tape_specifications
//   * Scrape flutter is a separate, higher-frequency component "above 1000 Hz" caused by the tape
//     vibrating against the head; it is not modelled here (it reads as a roughness, not a pitch
//     wobble, and a delay-line model at that rate would just sound like FM).
//   * Saturation: the magnetic transfer curve is a symmetric hysteresis loop, so tape distortion is
//     dominated by odd harmonics with a soft knee; the asymmetry that produces the small even-order
//     content comes from bias and head geometry. `DG_SAT_TAPE` is a soft symmetric curve with a
//     deliberate 15% asymmetry between half-cycles for exactly that reason.
//   * Head bump: "a damped oscillation in the low frequency output created by the limited length of
//     the head relative to the wavelength of the signal on tape", occurring where "the wavelength
//     of the recorded signal becomes about the effective width of the pole piece" — a few dB of
//     lift somewhere in 30-100 Hz depending on speed.
//     — https://www.tapeheads.net/threads/worst-head-bumps-ever.92176/,
//       https://ccrma.stanford.edu/~jay/subpages/Lectures/Lecture7-Magnetic_recording.pdf
//     Deliberately NOT modelled in M1: it needs its own resonant shelf and its own parameter, and
//     the parameter set for this task is fixed. It is the first thing to add.
//   * High-frequency loss has three named mechanisms — gap loss (output nulls when the recorded
//     wavelength equals the replay head gap), spacing loss (the medium not conforming to the head),
//     and self-erasure at the trailing edge of the record gap. All three are monotone rolloffs, so
//     one `highCut` knob covers them adequately.
//     — https://www.soundonsound.com/techniques/analogue-tape-machines
//
// Vinyl.
//   * Surface noise is high-frequency dominated: "the contact between the stylus and the groove
//     makes high frequency noise", which is precisely why the RIAA curve boosts treble on cut and
//     cuts it on playback — the playback de-emphasis takes the surface noise down with it.
//     — http://sessionville.com/articles/what-is-the-riaa-curve
//   * The RIAA playback curve is three time constants: 3180 us, 318 us and 75 us (poles at
//     50.05 Hz and 2122 Hz, zero at 500.5 Hz), roughly -20 dB of bass cut and +20 dB of treble
//     boost on the cutting side. — https://ledgernote.com/columns/mixing-mastering/riaa-curve/,
//     https://ez.analog.com/adiacademy/university-program/a/studentzone-articles/SA1094/testing-the-riaa-curve
//     The RIAA pair is not applied here: a correct encode/decode cascade is unity by construction,
//     so modelling it would cost cycles and change nothing. What it *does* justify is the shape of
//     the noise this chain generates — bright hiss, because that is what survives the de-emphasis.
//   * Rumble is low-frequency energy from the turntable bearing and from the cut itself; the DIN B
//     weighting used to measure it "centres on 315 Hz and has filters sloping away at 12 dB/octave
//     either side", and "rumble figures approaching 70 dB are very good", relative to a 1 kHz tone
//     at 70.7 mm/s lateral velocity (DIN 45 539).
//     — https://www.electronics-notes.com/articles/audio-video/vinyl-records-players/turntable.php
//     So the noise generator here is two components: bright hiss, plus a low-passed rumble bed.
//   * Crackle is impulsive, not stationary: "when the stylus encounters debris, it deflects
//     sideways and creates a crackling or popping sound".
//     — https://recordplayerlab.com/vinyl-crackle-pops-surface-noise/
//     There is no published distribution for how often and how loud, so this models it as a Poisson
//     process at `crackleDensity` events per second with a heavy-tailed amplitude (u^4, so most
//     ticks are small and the occasional one is loud) and a ~0.8 ms decay. That shape is chosen by
//     ear against records, not measured — stated plainly because it is the one part of this file
//     with no citation behind it.
//   * 33 1/3 rpm is 0.5556 revolutions per second, so once-per-revolution eccentricity wow on an
//     LP is at exactly 0.5556 Hz. That is where the vinyl preset puts it.
//
// Anti-aliased versus naive rate reduction.
//   A decimator is "an anti-aliasing lowpass filter followed by a downsampler"; without the filter
//   "high-frequency content folds into the passband and becomes indistinguishable from original
//   low-frequency content". — https://dspguru.com/dsp/faqs/multirate/decimation/,
//   https://www.mathworks.com/help/dsp/ug/overview-of-multirate-filters.html
//   The distinction matters here because the two produce musically different results. A naive
//   decimator folds every partial above the new Nyquist down to an inharmonic frequency: a hi-hat
//   becomes a cluster of tones that move the wrong way when you pitch the sample. A filtered
//   decimator removes those partials first, so what is left is an honest bandwidth limit. Both are
//   wanted — the first *is* the sound of an SP-1200 chop, the second is what you reach for when you
//   only want the bandwidth — so `antiAlias` selects between them rather than one being correct.
//   Note that `DG_AA_FILTERED` only suppresses the downward fold. The upward imaging from the
//   zero-order hold is kept in both modes on purpose: that is the missing reconstruction filter,
//   and removing it would throw away the brighter half of the SP-1200's character.
#ifndef CDEGRADE_H
#define CDEGRADE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Duration of the parameter ramp applied by `dg_set_params`, in milliseconds. The ramp is linear
/// and reaches the target exactly, which is what makes "settled" an exact state rather than an
/// asymptote.
#define DG_SMOOTH_MS 20.0

/// Nominal delay of the wow/flutter line, in milliseconds. This is the chain's latency whenever it
/// is not bypassed; see `dg_latency_frames`.
#define DG_DELAY_MS 8.0

/// Maximum peak swing of the wow/flutter delay, in milliseconds, in each direction. A sinusoidal
/// delay modulation of amplitude `A` seconds at `f` Hz produces a peak pitch deviation of
/// `2 * pi * f * A`, so this cap limits depth at low rates: 7 ms at 1 Hz caps depth at 4.4%, and at
/// 0.5 Hz at 2.2%. Real wow is 0.02%-0.4%, so this is roughly ten times more headroom than any
/// machine being modelled needs.
#define DG_SWING_MS 7.0

/// Simultaneous crackle events per channel. A tick lasts about 0.8 ms, so at the vinyl preset's
/// 12 events per second the expected overlap is 0.01 — eight slots is already far past generous,
/// and overruns simply skip a tick rather than allocate.
#define DG_CRACKLE_VOICES 8

/// Bit depths at or above this are treated as off, and the quantiser is skipped entirely.
#define DG_BITS_OFF 24.0f

typedef struct dg_state dg_t;

/// Saturation curve. Every curve is monotonically non-decreasing over the whole real line and
/// finite for any finite input at any drive, including absurd ones — see the tests.
///
/// Every curve is normalised by its slope at the origin, so a quiet signal passes at unity and
/// `drive` controls only how hard a loud one is squashed. `|output| <= |input|` therefore holds for
/// all of them at every drive — the saturation stage is a character control, never a level control,
/// and turning drive up cannot make a preset louder than the dry signal. (The usual alternative,
/// normalising at full scale, gives a small-signal gain of `drive / tanh(drive)`: +2.4 dB at drive
/// 1 and +8 dB at drive 2.5, which turns every A/B into a loudness contest.)
typedef enum dg_sat {
    /// No curve at all. `drive` still applies as a plain linear gain.
    DG_SAT_NONE = 0,
    /// `tanh(drive * x) / drive`. Symmetric, odd harmonics only, unity for small signals.
    DG_SAT_SOFT = 1,
    /// As `DG_SAT_SOFT` but with the negative half-cycle driven 15% harder, which is the small
    /// even-order content that tape's bias asymmetry contributes on top of its odd-harmonic
    /// hysteresis loop.
    DG_SAT_TAPE = 2,
    /// The same asymmetric shape pushed to 60%, for the lopsided transfer curve of a single-ended
    /// valve stage. Much more second harmonic.
    DG_SAT_TUBE = 3,
    /// A threshold clipper: unity below `1 / drive`, flat above it. Non-decreasing but, above the
    /// threshold, not strictly increasing.
    DG_SAT_HARD = 4,
} dg_sat;

/// Whether the sample-rate reducer filters before it decimates.
typedef enum dg_aa {
    /// Drop-sample: latch the current input sample and hold it. Content above the target Nyquist
    /// folds down into the band. This is the SP-1200's pitch-shifted path.
    DG_AA_NONE = 0,
    /// An 8th-order Butterworth lowpass at 0.45x the target rate runs before the hold, so nothing
    /// is left above the target Nyquist to fold. The hold's upward imaging is still kept.
    DG_AA_FILTERED = 1,
} dg_aa;

/// The whole parameter set. Plain data, no pointers, fixed layout; copy it, store it, diff it.
/// Initialise with `dg_params_default` or `dg_preset` — never from uninitialised memory, because
/// new fields will be added at the end.
typedef struct dg_params {
    /// Quantiser resolution in bits, continuous: 12.0 and 12.5 are both meaningful. The quantiser
    /// is mid-tread over `steps = 2^(bitDepth - 1)` intervals, so the output takes values `k/steps`
    /// for integer `k` clamped to `[-steps, steps - 1]` — the code range of a signed converter of
    /// that width, which is why full scale positive lands at `(steps-1)/steps` and not at 1.
    /// `>= DG_BITS_OFF` disables the stage entirely (bit-transparent, not "24-bit").
    float bitDepth;
    /// mu-law companding amount applied around the quantiser: the signal is compressed by
    /// `sign(x) * log(1 + mu|x|) / log(1 + mu)`, quantised, and expanded back, so the quantisation
    /// floor tracks the signal instead of sitting at a fixed level. 0 is linear (the SP-1200).
    /// The MPC60's format is documented only as "12-bit non-linear"; `mu = 40` on the MPC60 preset
    /// is an approximation of that, not a transcription of Akai's law.
    float companding;
    /// Sample rate the decimator holds to, in Hz. `<= 0` or `>= sampleRate` disables the stage.
    float targetSampleRate;
    /// A `dg_aa`. Stepped, not smoothed (see the note on smoothing below).
    int32_t antiAlias;
    /// How hard the signal is pushed into the saturation curve. With `DG_SAT_NONE` it is a plain
    /// linear gain and the only thing in the chain that can make a signal louder; with any curve it
    /// is normalised to unity small-signal gain, so it only ever compresses. 1 leaves every curve
    /// close to transparent.
    float drive;
    /// A `dg_sat`. Stepped, not smoothed.
    int32_t saturation;
    /// Peak pitch deviation as a fraction: 0.001 is 0.1%, the figure a cassette deck is specified
    /// in. Converted internally to a delay swing of `wowDepth / (2 * pi * wowRate)` seconds and
    /// clamped to `DG_SWING_MS`.
    float wowDepth;
    /// Rate of the wow oscillator in Hz. Below 4 Hz by convention; 0.5556 Hz is one LP revolution.
    float wowRate;
    /// Peak pitch deviation of the faster component, same units as `wowDepth`.
    float flutterDepth;
    /// Rate of the flutter oscillator in Hz. Above 4 Hz by convention.
    float flutterRate;
    /// Linear amplitude of the medium noise bed. Two components are generated together: bright
    /// hiss at this amplitude (first-difference filtered white, which tilts it up ~6 dB/octave, the
    /// spectrum RIAA de-emphasis leaves behind) and a rumble bed at 3x this amplitude lowpassed at
    /// 35 Hz. 0.002 is a reasonable "quiet pressing".
    float noiseLevel;
    /// Crackle events per second, as the rate of a Poisson process. Amplitude is drawn per event
    /// from a heavy-tailed distribution and is NOT scaled by `noiseLevel` — density is the only
    /// control, deliberately, because on a record the two are independent.
    float crackleDensity;
    /// Corner of the output rolloff in Hz: two cascaded one-poles, so -6 dB at this frequency and
    /// -12 dB/octave above it. `<= 0` or `>= sampleRate / 2` disables the stage (bit-transparent).
    float highCut;
    /// 0 is the untouched input, 1 is the fully processed signal. The dry path is delayed by
    /// exactly `dg_latency_frames`, so the two are sample-aligned and a partial mix does not comb.
    float mix;
    /// Seed for the noise and crackle PRNG. The same seed over the same input gives byte-identical
    /// output. Changing it in `dg_set_params` reseeds; passing the same value again does not, so
    /// turning any other knob does not restart the noise.
    uint64_t seed;
} dg_params_t;

/// The named parameter sets. Values and the reasoning behind each are in `degrade.c`.
typedef enum dg_preset {
    /// True bypass. See `dg_process` for exactly how strong that guarantee is.
    DG_PRESET_CLEAN = 0,
    DG_PRESET_SP1200 = 1,
    DG_PRESET_MPC60 = 2,
    DG_PRESET_CASSETTE = 3,
    DG_PRESET_VINYL = 4,
    DG_PRESET_RADIO = 5,
    DG_PRESET_COUNT = 6,
} dg_preset_t;

/// Fills `out` with the neutral parameter set: every stage off, mix 1. Identical to
/// `dg_preset(DG_PRESET_CLEAN, out)`.
void dg_params_default(dg_params_t *out);

/// Fills `out` with a preset. Out-of-range `which` yields the clean set.
void dg_preset(dg_preset_t which, dg_params_t *out);

/// Lowercase stable identifier for a preset ("sp1200", "clean", ...), or NULL if out of range.
/// These strings are the persisted names; do not rename them.
const char *dg_preset_name(dg_preset_t which);

/// Looks a preset up by the name `dg_preset_name` returns. Returns 0 and fills `out` on a match,
/// non-zero and leaves `out` alone otherwise.
int dg_preset_named(const char *name, dg_params_t *out);

/// Non-zero if this parameter set touches nothing at all — every stage off, or `mix <= 0`.
int dg_params_is_bypass(const dg_params_t *params);

/// Creates a chain for `channels` channels at `sampleRate`, starting from the clean parameter set.
/// Every buffer `dg_process` will ever need is allocated here and sized from the sample rate: the
/// wow/flutter delay lines, the anti-alias biquad state, the crackle voices and the per-channel
/// PRNGs. Returns NULL on invalid arguments or if allocation fails.
dg_t *dg_create(double sampleRate, int32_t channels);
void dg_destroy(dg_t *chain);

/// Publishes a new parameter set. Safe to call from the owner thread while the audio thread is in
/// `dg_process`, and safe in the strong sense: the struct is copied into a slot the audio thread is
/// not reading and published with a single release store of an epoch counter, which `dg_process`
/// picks up with one acquire load at the top of each block. There is no lock, no allocation, and no
/// unsynchronised word shared between the two threads. Every continuously-valued parameter then
/// ramps linearly to its new value over `DG_SMOOTH_MS`, so a knob turn does not click.
///
/// A consequence worth knowing: the new values take effect at the next block boundary, not
/// mid-block. At 512 frames and 48 kHz that is under 11 ms of granularity on top of a 20 ms ramp.
///
/// What is smoothed sample by sample: bit depth, companding, target rate, drive, wow and flutter
/// depth and rate, noise level, crackle density, high cut and mix.
///
/// What is not, and what that means:
///   * `saturation` and `antiAlias` are enumerations — they change at the next `dg_process` call.
///     Switching saturation type mid-note steps the transfer curve; with drive near unity the step
///     is tiny, with heavy drive it is audible. Change them between notes.
///   * The anti-alias filter's coefficients are recomputed once per block from the smoothed rate,
///     not per sample. During a ramp the cutoff therefore moves in block-sized steps; with a 20 ms
///     ramp that is two or three steps of a gentle filter and is not audible.
///   * The quantiser and the decimator are quantising stages by their nature. Their output steps by
///     at most one quantiser level or one held sample no matter how slowly you move the knob; the
///     ramp keeps the *parameter* continuous, not the signal.
///   * `seed` reseeds when it changes, which restarts the noise. That is a cut, not a ramp.
void dg_set_params(dg_t *chain, const dg_params_t *params);

/// Processes `frameCount` frames in place across the first `min(channelCount, channels)` planes of
/// `channels`. Planes past the chain's channel count are left untouched.
///
/// Allocates nothing, takes no lock, and calls nothing that could block. Deterministic given the
/// seed and the starting state.
///
/// Bypass: a chain created (or `dg_reset`) with bypass parameters, and never given non-bypass
/// parameters since, returns immediately without reading or writing a single sample. That is what
/// makes the `clean` preset bit-transparent rather than merely quiet. Once non-bypass parameters
/// have been set, the chain stays on the audio path until the next `dg_reset`, even if it is later
/// set back to clean — because dropping out of the path would jump the signal forward by
/// `dg_latency_frames` and click. Setting `clean` on a running chain therefore ramps to a
/// transparent-but-delayed path, which is the right behaviour for a mix knob and the wrong
/// behaviour for a hard bypass switch; use `dg_reset` for the latter.
void dg_process(dg_t *chain, float *const *channels, int32_t channelCount, int32_t frameCount);

/// Clears every filter, delay line and crackle voice, reseeds the PRNG from the current parameters,
/// snaps all smoothed parameters to their targets, and re-enters bypass if the current parameters
/// are bypass parameters. Call it when the audio thread is not in `dg_process`.
void dg_reset(dg_t *chain);

/// Latency of the chain in frames — the wow/flutter line's nominal delay, `DG_DELAY_MS` rounded to
/// a whole frame. Constant for the life of the chain. It is 0 while `dg_bypassed` is non-zero, and
/// that is the only time it is 0. The dry half of `mix` is delayed by the same amount, so the
/// correction an offline bounce needs is this many frames for the whole chain, at any mix.
int32_t dg_latency_frames(const dg_t *chain);

/// Non-zero while the chain is in true bypass, per the rule in `dg_process`.
int dg_bypassed(const dg_t *chain);

/// Sample rate and channel count the chain was created with.
double dg_sample_rate(const dg_t *chain);
int32_t dg_channel_count(const dg_t *chain);

#ifdef __cplusplus
}
#endif

#endif
