// The degradation chain. See include/CDegrade.h for the contract and for where every number in
// the presets comes from.
//
// Everything the audio thread touches is allocated in dg_create and lives until dg_destroy: the
// per-channel delay lines, the anti-alias biquad state, the crackle voices and the PRNG states.
// dg_process takes no lock, allocates nothing, and reads no global that anything else writes.
//
// Signal order, and why:
//
//   input -> [wow/flutter delay line] -> [drive + saturation] -> [anti-alias LPF] -> [hold]
//         -> [quantise] -> [medium noise + crackle] -> [high cut] -> [mix with delayed dry]
//
// The transport wobble comes first because on the real machines it is the source medium moving
// under the head or the stylus, before anything digital happens — so a record with wow, sampled
// into an SP-1200, gets its wobble quantised along with everything else. Drive sits next because
// it is the input stage of the converter, or the tape's own magnetics, and it has to happen before
// the bandwidth limit or the harmonics it generates would be filtered away rather than folded.
// The filter and the hold are the converter. The quantiser is the word length. Medium noise is
// added after the converter rather than before it, so that turning a record's surface noise up does
// not also change how the quantiser dithers — the two are independent controls and keeping them
// independent is worth the small inauthenticity. The high cut is the analog output filter. The mix
// is last, against a dry signal delayed by exactly the same nominal amount, so a partial mix does
// not comb.

#include "CDegrade.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Determinism, for the same reason as the render core: left alone, the compiler may or may not
// contract `a + b * c` into an FMA depending on the optimisation level and the target, which would
// make "same seed, same bytes" hold only within one build.
#pragma STDC FP_CONTRACT OFF

#if defined(__x86_64__) || defined(__i386__)
#include <pmmintrin.h>
#include <xmmintrin.h>
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#define DG_TWO_PI 6.283185307179586f

// MARK: - Denormal flushing
//
// Same reasoning as the render core: the high-cut one-poles, the rumble lowpass and the crackle
// envelopes all decay asymptotically towards zero, which walks straight into denormal territory
// where some cores take a microcoded slow path costing hundreds of cycles per operation. Flush to
// zero for the duration of the call and restore the caller's mode on the way out. Flushing is
// deterministic on a given machine, so it does not compromise the same-seed-same-bytes guarantee.

#if defined(__aarch64__)
#define DG_FPCR_FZ (1ull << 24)
typedef uint64_t dg_fp_mode_t;
static inline dg_fp_mode_t dg_fp_mode_begin(void) {
    uint64_t v;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(v));
    const uint64_t n = v | DG_FPCR_FZ;
    if (n != v) __asm__ __volatile__("msr fpcr, %0" : : "r"(n));
    return v;
}
static inline void dg_fp_mode_end(dg_fp_mode_t v) {
    __asm__ __volatile__("msr fpcr, %0" : : "r"(v));
}
#elif defined(__x86_64__) || defined(__i386__)
typedef unsigned int dg_fp_mode_t;
static inline dg_fp_mode_t dg_fp_mode_begin(void) {
    const unsigned int v = _mm_getcsr();
    _mm_setcsr(v | 0x8040u); // FTZ | DAZ
    return v;
}
static inline void dg_fp_mode_end(dg_fp_mode_t v) { _mm_setcsr(v); }
#else
typedef int dg_fp_mode_t;
static inline dg_fp_mode_t dg_fp_mode_begin(void) { return 0; }
static inline void dg_fp_mode_end(dg_fp_mode_t v) { (void)v; }
#endif

/// Order of the anti-alias filter, as biquad sections. 12th-order Butterworth, cut at 0.45x the
/// target rate. That choice is load bearing: an 8th-order version measured only 41 dB of alias
/// suppression on the tests' 9 kHz-into-12 kHz case, because 9 kHz is barely three quarters of an
/// octave into the stopband and Butterworth is gentle near its corner. 12th order measures around
/// 60 dB on the same case, which is margin rather than a coin flip.
#define DG_AA_SECTIONS 6

/// Decay time constant of one crackle tick, in seconds.
#define DG_CRACKLE_TAU 0.0008f

/// Peak amplitude a crackle tick can reach. Amplitude is drawn as `(0.05 + 0.95 * u^4)` times this,
/// so the median tick is around 1% of full scale and roughly one in twenty is over a third of the
/// peak — chosen by ear against records, not measured.
#define DG_CRACKLE_PEAK 0.25f

/// Corner of the rumble lowpass, in Hz.
#define DG_RUMBLE_HZ 35.0f

/// Rumble amplitude relative to the hiss, before the makeup gain that compensates for what the
/// lowpass takes out of white noise.
#define DG_RUMBLE_RATIO 3.0f

/// Largest drive accepted. Anything above this is clamped, which is what keeps `0 * INFINITY` out
/// of the saturation curves when a caller passes something absurd.
#define DG_DRIVE_MAX 1.0e6f

/// Number of parameter slots in the publication ring. `dg_set_params` writes the slot the audio
/// thread is not reading and publishes it with one release store of an epoch counter; the audio
/// thread takes one acquire load per block. Four slots rather than two so that a caller spinning
/// the same knob cannot lap the reader inside a single block — a torn parameter set would still be
/// harmless, since every field would be an in-range value from one publish or another, but four
/// slots make it not happen.
#define DG_PARAM_SLOTS 4

/// Default seed for presets that generate noise. Golden-ratio constant; nothing special about it
/// beyond being non-zero and well mixed.
#define DG_DEFAULT_SEED 0x9E3779B97F4A7C15ULL

// MARK: - Smoothed parameters
//
// One linear ramp shared by every continuously-valued parameter. Linear rather than one-pole
// because a linear ramp reaches its target exactly and then stops, which makes "settled" a state
// the code can test rather than an asymptote it has to threshold.

enum {
    DG_S_BITS = 0,   // quantiser width in bits; >= DG_BITS_OFF means off
    DG_S_MU,         // companding mu; 0 means linear
    DG_S_RATEINC,    // target rate / sample rate, in (0, 1); 0 means off
    DG_S_DRIVE,      // linear gain into the saturation curve
    DG_S_WOWAMP,     // wow delay swing, in frames
    DG_S_WOWINC,     // wow phase increment, radians per frame
    DG_S_FLUTAMP,    // flutter delay swing, in frames
    DG_S_FLUTINC,    // flutter phase increment, radians per frame
    DG_S_NOISE,      // hiss amplitude
    DG_S_CRACKLE,    // crackle spawn probability per frame
    DG_S_HFCOEF,     // one-pole coefficient of the high cut; 1 means off
    DG_S_MIX,        // 0 dry .. 1 wet
    DG_S_COUNT
};

typedef struct {
    float b0, b1, b2, a1, a2;
} dg_biquad_co;

typedef struct {
    float z1, z2;
} dg_biquad_st;

typedef struct {
    float amp;
    float env;
} dg_crackle_voice;

typedef struct {
    float *delay;                      // delay line, dlLen frames
    dg_biquad_st aa[DG_AA_SECTIONS];   // anti-alias filter state
    float hold;                        // last latched sample of the decimator
    float hf1, hf2;                    // the two cascaded one-poles of the high cut
    float prevWhite;                   // previous white sample, for the hiss tilt
    float rumble;                      // rumble lowpass state
    uint64_t rng;                      // per-channel PRNG state
    dg_crackle_voice crackle[DG_CRACKLE_VOICES];
} dg_channel;

struct dg_state {
    double sampleRate;
    int32_t channels;

    // Parameter publication. The owner thread writes `slots[(epoch + 1) % DG_PARAM_SLOTS]` and then
    // release-stores the new epoch; the audio thread acquire-loads the epoch at the top of a block
    // and, if it moved, copies that slot into `active` and re-derives. Nothing else crosses the two
    // threads, so `dg_set_params` really is safe to call under `dg_process` rather than merely
    // usually safe.
    dg_params_t slots[DG_PARAM_SLOTS];
    _Atomic int64_t paramEpoch;
    int64_t paramEpochSeen;            // audio thread only
    dg_params_t active;                // audio thread's copy of the published set

    /// 1 while the chain has never been given non-bypass parameters since create or reset. Only the
    /// owner thread clears it (in `dg_set_params`) and only create/reset set it; the audio thread
    /// reads it and nothing else.
    _Atomic int32_t bypassLatch;

    float cur[DG_S_COUNT];
    float tgt[DG_S_COUNT];
    float inc[DG_S_COUNT];
    int32_t rampLeft;
    int32_t rampFrames;

    int32_t satType;                   // stepped at block boundaries, not smoothed
    int32_t aaMode;

    dg_channel *ch;
    float *delayStorage;               // one allocation backing every channel's delay line

    int32_t dlLen;                     // power of two
    int32_t dlMask;
    int32_t writeIndex;
    int32_t nominalDelay;              // DG_DELAY_MS in frames, exactly; also the reported latency
    float maxSwing;                    // DG_SWING_MS in frames

    float wowPhase;
    float flutPhase;
    float holdPhase;

    dg_biquad_co aaCo[DG_AA_SECTIONS];
    float aaCutoff;                    // cutoff the coefficients were computed for, in Hz
    int32_t aaWasActive;

    float crackleDecay;                // per-frame envelope multiplier
    float rumbleCoef;
    float rumbleMakeup;
};

// MARK: - PRNG
//
// xorshift64*. Small, fast, deterministic, and — unlike `rand()` — carried entirely in the state,
// so two chains with the same seed produce the same bytes no matter what else is running.

static inline uint64_t dg_rng_next(uint64_t *s) {
    uint64_t x = *s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *s = x;
    return x * 0x2545F4914F6CDD1DULL;
}

/// Uniform in [0, 1), 24 bits of mantissa.
static inline float dg_rng_uniform(uint64_t *s) {
    return (float)(dg_rng_next(s) >> 40) * (1.0f / 16777216.0f);
}

/// Uniform in [-1, 1).
static inline float dg_rng_bipolar(uint64_t *s) {
    return dg_rng_uniform(s) * 2.0f - 1.0f;
}

/// splitmix64, used once per channel to turn one seed into decorrelated per-channel streams.
static uint64_t dg_splitmix(uint64_t *s) {
    uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static void dg_seed_channels(struct dg_state *st, uint64_t seed) {
    uint64_t s = seed ? seed : 0xD1B54A32D192ED03ULL;
    for (int32_t c = 0; c < st->channels; c++) {
        uint64_t v = dg_splitmix(&s);
        st->ch[c].rng = v ? v : 0x9E3779B97F4A7C15ULL;
    }
}

// MARK: - Small helpers

static inline float dg_clampf(float v, float lo, float hi) {
    if (!(v >= lo)) return lo;   // NaN-safe: a NaN fails every comparison and lands on lo
    if (v > hi) return hi;
    return v;
}

static int32_t dg_next_pow2(int32_t v) {
    int32_t n = 1;
    while (n < v) n <<= 1;
    return n;
}

/// 4-point Catmull-Rom, `ym1 .. y2` in increasing time order, `t` in [0, 1] between y0 and y1.
static inline float dg_hermite(float ym1, float y0, float y1, float y2, float t) {
    const float c0 = y0;
    const float c1 = 0.5f * (y1 - ym1);
    const float c2 = ym1 - 2.5f * y0 + 2.0f * y1 - 0.5f * y2;
    const float c3 = 0.5f * (y2 - ym1) + 1.5f * (y0 - y1);
    return ((c3 * t + c2) * t + c1) * t + c0;
}

/// RBJ lowpass. `fc` and `fs` in Hz.
static void dg_biquad_lowpass(dg_biquad_co *co, double fc, double fs, double q) {
    double w0 = 2.0 * M_PI * fc / fs;
    if (w0 > 0.99 * M_PI) w0 = 0.99 * M_PI;
    if (w0 < 1e-6) w0 = 1e-6;
    const double cw = cos(w0);
    const double alpha = sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    co->b0 = (float)(((1.0 - cw) * 0.5) / a0);
    co->b1 = (float)((1.0 - cw) / a0);
    co->b2 = co->b0;
    co->a1 = (float)((-2.0 * cw) / a0);
    co->a2 = (float)((1.0 - alpha) / a0);
}

static inline float dg_biquad_tick(const dg_biquad_co *co, dg_biquad_st *st, float x) {
    const float y = co->b0 * x + st->z1;
    st->z1 = co->b1 * x - co->a1 * y + st->z2;
    st->z2 = co->b2 * x - co->a2 * y;
    return y;
}

/// Saturation. Every branch is non-decreasing in `x` over the whole real line, passes through the
/// origin, and is finite for any finite `x` once `drive` has been clamped by `dg_derive`.
///
/// Every curve is normalised by its own slope at the origin, so a quiet signal passes at unity
/// gain and `drive` decides only how hard a loud one gets squashed. That is deliberate, and it is
/// the difference between a character control and a volume control: with the more common
/// "normalise at full scale" convention (`tanh(d x) / tanh(d)`) the small-signal gain is
/// `d / tanh(d)`, which is already +2.4 dB at drive 1 and +8 dB at drive 2.5 — so every preset with
/// any drive in it would come back louder than the dry signal and A/B would be a loudness contest.
/// With this normalisation `|y| <= |x|` holds for every curve at every drive (tanh(u) <= u, and a
/// clamp only ever reduces), which the tests assert.
static inline float dg_saturate(float x, float drive, int32_t type) {
    const float d = drive < 1.0e-4f ? 1.0e-4f : drive;
    switch (type) {
        case DG_SAT_HARD: {
            // Normalised, a hard clip is a threshold clipper: unity below 1/drive, flat above it.
            const float v = x * d;
            const float c = v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v);
            return c / d;
        }
        case DG_SAT_SOFT:
        case DG_SAT_TAPE:
        case DG_SAT_TUBE: {
            float k = d;
            if (x < 0.0f) {
                // The asymmetry is what produces even-order harmonics: tape's hysteresis loop is
                // very nearly symmetric (odd harmonics), bias and head geometry skew it slightly;
                // a single-ended valve stage is skewed a great deal more.
                const float asym = (type == DG_SAT_TAPE) ? 1.15f : (type == DG_SAT_TUBE ? 1.60f : 1.0f);
                k = d * asym;
            }
            return tanhf(k * x) / d;
        }
        default:
            // No curve: `drive` is exactly a linear gain, and this is the one branch that can make
            // a signal louder.
            return x * drive;
    }
}

/// Mid-tread quantiser over `steps` intervals per unit, optionally through a mu-law companding
/// pair. `muLog` is `log1p(mu)` and `muLogInv` its reciprocal, hoisted out of the channel loop.
static inline float dg_quantise(float x, float steps, float mu, float muLog, float muLogInv) {
    float v = x;
    if (mu > 0.0f) {
        float a = fabsf(v);
        if (a > 1.0f) a = 1.0f;
        const float s = (v < 0.0f) ? -1.0f : 1.0f;
        v = s * log1pf(mu * a) * muLogInv;
    }
    float q = floorf(v * steps + 0.5f);
    const float hi = steps - 1.0f;
    const float lo = -steps;
    if (q > hi) q = hi;
    if (q < lo) q = lo;
    v = q / steps;
    if (mu > 0.0f) {
        const float a = fabsf(v);
        const float s = (v < 0.0f) ? -1.0f : 1.0f;
        v = s * expm1f(a * muLog) / mu;
    }
    return v;
}

// MARK: - Parameter derivation

static void dg_derive(const struct dg_state *st, const dg_params_t *p, float *out) {
    const float fs = (float)st->sampleRate;

    float bits = p->bitDepth;
    if (!(bits < DG_BITS_OFF)) bits = DG_BITS_OFF;
    if (bits < 1.0f) bits = 1.0f;
    out[DG_S_BITS] = bits;

    out[DG_S_MU] = dg_clampf(p->companding, 0.0f, 1.0e5f);

    float rateInc = 0.0f;
    if (p->targetSampleRate > 0.0f && p->targetSampleRate < fs) rateInc = p->targetSampleRate / fs;
    out[DG_S_RATEINC] = rateInc;

    out[DG_S_DRIVE] = dg_clampf(p->drive, 0.0f, DG_DRIVE_MAX);

    // A sinusoidal delay modulation of amplitude A seconds at f Hz gives a peak pitch deviation of
    // 2*pi*f*A, so the swing a requested depth needs is depth / (2*pi*f).
    float wowAmp = 0.0f, wowInc = 0.0f;
    if (p->wowRate > 0.0f && p->wowDepth > 0.0f) {
        const float rate = dg_clampf(p->wowRate, 0.01f, fs * 0.25f);
        wowAmp = (dg_clampf(p->wowDepth, 0.0f, 10.0f) / (DG_TWO_PI * rate)) * fs;
        wowInc = DG_TWO_PI * rate / fs;
    }
    float flutAmp = 0.0f, flutInc = 0.0f;
    if (p->flutterRate > 0.0f && p->flutterDepth > 0.0f) {
        const float rate = dg_clampf(p->flutterRate, 0.01f, fs * 0.25f);
        flutAmp = (dg_clampf(p->flutterDepth, 0.0f, 10.0f) / (DG_TWO_PI * rate)) * fs;
        flutInc = DG_TWO_PI * rate / fs;
    }
    // The two oscillators share one delay line, so their combined swing is what has to fit.
    const float total = wowAmp + flutAmp;
    if (total > st->maxSwing && total > 0.0f) {
        const float scale = st->maxSwing / total;
        wowAmp *= scale;
        flutAmp *= scale;
    }
    out[DG_S_WOWAMP] = wowAmp;
    out[DG_S_WOWINC] = wowInc;
    out[DG_S_FLUTAMP] = flutAmp;
    out[DG_S_FLUTINC] = flutInc;

    out[DG_S_NOISE] = dg_clampf(p->noiseLevel, 0.0f, 4.0f);
    out[DG_S_CRACKLE] = dg_clampf(p->crackleDensity / fs, 0.0f, 1.0f);

    float hf = 1.0f;
    if (p->highCut > 0.0f && p->highCut < fs * 0.5f) {
        hf = 1.0f - expf(-DG_TWO_PI * p->highCut / fs);
        hf = dg_clampf(hf, 1.0e-6f, 1.0f);
    }
    out[DG_S_HFCOEF] = hf;

    out[DG_S_MIX] = dg_clampf(p->mix, 0.0f, 1.0f);
}

int dg_params_is_bypass(const dg_params_t *p) {
    if (!p) return 1;
    // Fully dry is bypass no matter what the stages say.
    if (!(p->mix > 0.0f)) return 1;
    if (p->bitDepth < DG_BITS_OFF) return 0;
    // No sample rate in scope here, so "any positive value" is treated as active. Presets use 0
    // for off, which is what makes the clean set detectable.
    if (p->targetSampleRate > 0.0f) return 0;
    if (p->saturation != DG_SAT_NONE) return 0;
    if (p->drive != 1.0f) return 0;
    if (p->wowDepth > 0.0f && p->wowRate > 0.0f) return 0;
    if (p->flutterDepth > 0.0f && p->flutterRate > 0.0f) return 0;
    if (p->noiseLevel > 0.0f) return 0;
    if (p->crackleDensity > 0.0f) return 0;
    if (p->highCut > 0.0f) return 0;
    return 1;
}

// MARK: - Presets
//
// clean     — nothing at all. True bypass, asserted bit-transparent in the tests.
//
// sp1200    — 12 bits linear and 26.04 kHz, both straight off Rossum's own spec for the machine,
//             with the decimator in its unfiltered mode because the SP-1200's famous artifacts are
//             exactly what an unfiltered drop-sample path produces. 12 kHz high cut because the
//             Nyquist of 26.04 kHz is 13.02 kHz and the analog output stage sits below it; a touch
//             of drive into a soft curve stands in for that output stage.
//
// mpc60     — 12 bits again but companded, and 40 kHz, so the Nyquist is 20 kHz instead of
//             13.02 kHz. The 17 kHz high cut follows the machine's quoted ~18 kHz response. The
//             decimator is filtered, because the difference between these two machines is not that
//             one aliases harder, it is that the Akai keeps its top end and its noise floor follows
//             the signal. Side by side this should read as thick and punchy where the SP-1200 reads
//             as dark and gritty.
//
// cassette  — no converter at all, just transport and magnetics. 0.12% wow at 0.9 Hz and 0.06%
//             flutter at 7.5 Hz: a hi-fi deck is specified at 0.08% weighted and hi-fi minimum is
//             +/-0.2%, and the 4 Hz split between the two names is the convention. Tape curve at
//             1.6x drive, hiss at about -60 dBFS, and a 14 kHz corner for the gap and spacing
//             losses that give a cassette its dull top.
//
// vinyl     — wow at 0.5556 Hz because 33 1/3 rpm is 0.5556 revolutions per second and an
//             off-centre spindle hole wobbles once per revolution. Surface noise a little above the
//             cassette's, because the generator's bright-hiss-plus-rumble split is the shape RIAA
//             de-emphasis leaves behind, and 12 ticks a second of crackle. Gentle drive and a
//             16 kHz corner: a record is not a lo-fi medium, it is a noisy one.
//
// radio     — a small speaker at the end of a broadcast chain: heavy soft limiting (3x into the
//             soft curve), a 4.5 kHz corner, static hiss and a few atmospheric ticks a second.
//             Known gap: there is no low cut in this parameter set, so this does not thin out the
//             bass the way a real pocket radio does. Reach for it as a texture, not an impression.

static const dg_params_t dg_presets[DG_PRESET_COUNT] = {
    // clean
    { DG_BITS_OFF, 0.0f, 0.0f, DG_AA_FILTERED, 1.0f, DG_SAT_NONE,
      0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0ULL },
    // sp1200
    { 12.0f, 0.0f, 26040.0f, DG_AA_NONE, 1.40f, DG_SAT_SOFT,
      0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 12000.0f, 1.0f, DG_DEFAULT_SEED },
    // mpc60
    { 12.0f, 40.0f, 40000.0f, DG_AA_FILTERED, 1.20f, DG_SAT_SOFT,
      0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 17000.0f, 1.0f, DG_DEFAULT_SEED },
    // cassette
    { DG_BITS_OFF, 0.0f, 0.0f, DG_AA_FILTERED, 1.80f, DG_SAT_TAPE,
      0.0012f, 0.90f, 0.0006f, 7.50f, 0.0015f, 0.0f, 14000.0f, 1.0f, DG_DEFAULT_SEED },
    // vinyl
    { DG_BITS_OFF, 0.0f, 0.0f, DG_AA_FILTERED, 1.20f, DG_SAT_SOFT,
      0.0025f, 0.5556f, 0.0006f, 8.0f, 0.0025f, 12.0f, 16000.0f, 1.0f, DG_DEFAULT_SEED },
    // radio
    { DG_BITS_OFF, 0.0f, 0.0f, DG_AA_FILTERED, 3.00f, DG_SAT_SOFT,
      0.0f, 0.0f, 0.0f, 0.0f, 0.0008f, 3.0f, 4500.0f, 1.0f, DG_DEFAULT_SEED },
};

static const char *const dg_preset_names[DG_PRESET_COUNT] = {
    "clean", "sp1200", "mpc60", "cassette", "vinyl", "radio",
};

void dg_params_default(dg_params_t *out) {
    dg_preset(DG_PRESET_CLEAN, out);
}

void dg_preset(dg_preset_t which, dg_params_t *out) {
    if (!out) return;
    if (which < 0 || which >= DG_PRESET_COUNT) which = DG_PRESET_CLEAN;
    *out = dg_presets[which];
}

const char *dg_preset_name(dg_preset_t which) {
    if (which < 0 || which >= DG_PRESET_COUNT) return NULL;
    return dg_preset_names[which];
}

int dg_preset_named(const char *name, dg_params_t *out) {
    if (!name || !out) return 1;
    for (int32_t i = 0; i < DG_PRESET_COUNT; i++) {
        if (strcmp(name, dg_preset_names[i]) == 0) {
            *out = dg_presets[i];
            return 0;
        }
    }
    return 1;
}

// MARK: - Lifetime

dg_t *dg_create(double sampleRate, int32_t channels) {
    if (!(sampleRate > 0.0) || channels <= 0 || channels > 64) return NULL;

    struct dg_state *st = (struct dg_state *)calloc(1, sizeof(struct dg_state));
    if (!st) return NULL;

    st->sampleRate = sampleRate;
    st->channels = channels;

    st->nominalDelay = (int32_t)lround(DG_DELAY_MS * 0.001 * sampleRate);
    if (st->nominalDelay < 2) st->nominalDelay = 2;
    int32_t swing = (int32_t)ceil(DG_SWING_MS * 0.001 * sampleRate);
    if (swing < 1) swing = 1;
    // Never let the swing reach a delay the interpolator cannot read four taps around.
    if (swing > st->nominalDelay - 2) swing = st->nominalDelay - 2;
    if (swing < 0) swing = 0;
    st->maxSwing = (float)swing;

    st->dlLen = dg_next_pow2(st->nominalDelay + swing + 8);
    st->dlMask = st->dlLen - 1;

    st->ch = (dg_channel *)calloc((size_t)channels, sizeof(dg_channel));
    st->delayStorage = (float *)calloc((size_t)channels * (size_t)st->dlLen, sizeof(float));
    if (!st->ch || !st->delayStorage) {
        free(st->ch);
        free(st->delayStorage);
        free(st);
        return NULL;
    }
    for (int32_t c = 0; c < channels; c++) {
        st->ch[c].delay = st->delayStorage + (size_t)c * (size_t)st->dlLen;
    }

    st->rampFrames = (int32_t)lround(DG_SMOOTH_MS * 0.001 * sampleRate);
    if (st->rampFrames < 1) st->rampFrames = 1;

    st->crackleDecay = expf(-1.0f / (DG_CRACKLE_TAU * (float)sampleRate));
    st->rumbleCoef = 1.0f - expf(-DG_TWO_PI * DG_RUMBLE_HZ / (float)sampleRate);
    st->rumbleCoef = dg_clampf(st->rumbleCoef, 1.0e-6f, 1.0f);
    // A one-pole at coefficient `a` leaves white noise with sqrt(a / (2 - a)) of its RMS, so this
    // puts the rumble bed back on the same scale as the hiss before DG_RUMBLE_RATIO is applied.
    st->rumbleMakeup = sqrtf((2.0f - st->rumbleCoef) / st->rumbleCoef);

    dg_preset(DG_PRESET_CLEAN, &st->slots[0]);
    st->active = st->slots[0];
    atomic_store_explicit(&st->paramEpoch, 0, memory_order_relaxed);
    st->paramEpochSeen = 0;
    dg_derive(st, &st->active, st->tgt);
    memcpy(st->cur, st->tgt, sizeof(st->cur));
    st->satType = st->active.saturation;
    st->aaMode = st->active.antiAlias;
    st->rampLeft = 0;
    st->holdPhase = 1.0f;
    st->aaCutoff = -1.0f;
    atomic_store_explicit(&st->bypassLatch, dg_params_is_bypass(&st->active), memory_order_relaxed);
    dg_seed_channels(st, st->active.seed);

    return st;
}

void dg_destroy(dg_t *chain) {
    if (!chain) return;
    free(chain->delayStorage);
    free(chain->ch);
    free(chain);
}

/// Defined with the parameter handoff below; reset adopts through it too.
static int64_t dg_read_published(struct dg_state *st, dg_params_t *out);

void dg_reset(dg_t *chain) {
    struct dg_state *st = chain;
    if (!st) return;
    memset(st->delayStorage, 0, (size_t)st->channels * (size_t)st->dlLen * sizeof(float));
    for (int32_t c = 0; c < st->channels; c++) {
        dg_channel *ch = &st->ch[c];
        memset(ch->aa, 0, sizeof(ch->aa));
        memset(ch->crackle, 0, sizeof(ch->crackle));
        ch->hold = 0.0f;
        ch->hf1 = ch->hf2 = 0.0f;
        ch->prevWhite = 0.0f;
        ch->rumble = 0.0f;
    }
    st->writeIndex = 0;
    st->wowPhase = 0.0f;
    st->flutPhase = 0.0f;
    st->holdPhase = 1.0f;
    st->aaCutoff = -1.0f;
    st->aaWasActive = 0;
    // Adopt whatever was published last, without a ramp: reset is a cut by definition.
    dg_params_t published;
    const int64_t epoch = dg_read_published(st, &published);
    if (epoch >= 0) {
        st->active = published;
        st->paramEpochSeen = epoch;
    }
    dg_derive(st, &st->active, st->tgt);
    memcpy(st->cur, st->tgt, sizeof(st->cur));
    st->rampLeft = 0;
    st->satType = st->active.saturation;
    st->aaMode = st->active.antiAlias;
    dg_seed_channels(st, st->active.seed);
    atomic_store_explicit(&st->bypassLatch, dg_params_is_bypass(&st->active), memory_order_relaxed);
}

int32_t dg_latency_frames(const dg_t *chain) {
    if (!chain) return 0;
    return dg_bypassed(chain) ? 0 : chain->nominalDelay;
}

int dg_bypassed(const dg_t *chain) {
    if (!chain) return 1;
    return atomic_load_explicit(&chain->bypassLatch, memory_order_relaxed) != 0;
}
double dg_sample_rate(const dg_t *chain) { return chain ? chain->sampleRate : 0.0; }
int32_t dg_channel_count(const dg_t *chain) { return chain ? chain->channels : 0; }

// MARK: - Parameters

/// Copies the newest published parameter set into `out` and returns its epoch.
///
/// The ring alone was not enough. A writer publishing in a tight loop can come all the way round
/// the ring while the reader is copying a slot — which needs no more than the audio thread being
/// descheduled mid-copy on a loaded machine — and the reader then holds a set torn between two
/// publishes. So this is a seqlock read: copy the slot, re-read the epoch, and if the writer has
/// advanced far enough that it could have been writing *this* slot during the copy, copy again
/// from the newer epoch. The writer publishes slot `e` only after writing it, so slot `e % N` is
/// rewritten no earlier than epoch `e + N - 1` begins; a reread within `N - 2` of the start is safe.
///
/// Bounded, for the audio thread: after `DG_ADOPT_ATTEMPTS` laps it returns -1 and the caller
/// keeps the parameters it already had, which is a slightly late knob rather than a torn one.
#define DG_ADOPT_ATTEMPTS 4
static int64_t dg_read_published(struct dg_state *st, dg_params_t *out) {
    int64_t epoch = atomic_load_explicit(&st->paramEpoch, memory_order_acquire);
    for (int attempt = 0; attempt < DG_ADOPT_ATTEMPTS; attempt++) {
        *out = st->slots[(size_t)(epoch % DG_PARAM_SLOTS)];
        atomic_thread_fence(memory_order_acquire);
        const int64_t after = atomic_load_explicit(&st->paramEpoch, memory_order_relaxed);
        if (after - epoch <= DG_PARAM_SLOTS - 2) return epoch;
        epoch = after;
    }
    return -1;
}

void dg_set_params(dg_t *chain, const dg_params_t *params) {
    struct dg_state *st = chain;
    if (!st || !params) return;

    // Leaving bypass is the owner thread's decision and has to be visible before the parameters
    // that caused it, or the audio thread could pick up dirty parameters while still short-circuiting
    // on the latch.
    if (!dg_params_is_bypass(params)) {
        atomic_store_explicit(&st->bypassLatch, 0, memory_order_relaxed);
    }

    const int64_t epoch = atomic_load_explicit(&st->paramEpoch, memory_order_relaxed) + 1;
    st->slots[(size_t)(epoch % DG_PARAM_SLOTS)] = *params;
    atomic_store_explicit(&st->paramEpoch, epoch, memory_order_release);
}

/// Picks up a newly published parameter set, on the audio thread. Bounded work, no allocation: a
/// struct copy, `dg_derive` (about thirty operations and two transcendentals), and at most 64
/// PRNG reseeds.
static void dg_adopt_params(struct dg_state *st) {
    if (atomic_load_explicit(&st->paramEpoch, memory_order_acquire) == st->paramEpochSeen) return;

    dg_params_t published;
    const int64_t epoch = dg_read_published(st, &published);
    if (epoch < 0) return;   // lapped every attempt: keep the current set, try again next block

    const uint64_t oldSeed = st->active.seed;
    st->active = published;
    st->paramEpochSeen = epoch;

    dg_derive(st, &st->active, st->tgt);
    st->satType = st->active.saturation;
    st->aaMode = st->active.antiAlias;

    // Reseeding restarts the noise, so it only happens when the seed actually changed — turning any
    // other knob must not make the surface noise jump.
    if (st->active.seed != oldSeed) dg_seed_channels(st, st->active.seed);

    const int32_t n = st->rampFrames;
    const float invN = 1.0f / (float)n;
    for (int32_t i = 0; i < DG_S_COUNT; i++) {
        st->inc[i] = (st->tgt[i] - st->cur[i]) * invN;
    }
    st->rampLeft = n;
}

// MARK: - Render

static void dg_update_aa(struct dg_state *st, float rateInc) {
    const float target = rateInc * (float)st->sampleRate;
    float cutoff = 0.45f * target;
    const float ceiling = 0.45f * (float)st->sampleRate;
    if (cutoff > ceiling) cutoff = ceiling;
    // Floor the corner at a thousandth of the sample rate. Below that the high-Q sections start to
    // lose their coefficients to single-precision state, and a target rate under fs/450 is a sound
    // effect rather than a converter anyway.
    const float floorHz = (float)st->sampleRate * 0.001f;
    if (cutoff < floorHz) cutoff = floorHz;
    if (st->aaCutoff > 0.0f && fabsf(cutoff - st->aaCutoff) < st->aaCutoff * 0.001f) return;

    // 12th-order Butterworth section Qs: 1 / (2 cos(pi (2k+1) / 24)) for k = 0..5.
    static const double kQ[DG_AA_SECTIONS] = {
        0.504314, 0.541196, 0.630236, 0.821434, 1.306563, 3.830649,
    };
    for (int32_t s = 0; s < DG_AA_SECTIONS; s++) {
        dg_biquad_lowpass(&st->aaCo[s], cutoff, st->sampleRate, kQ[s]);
    }
    st->aaCutoff = cutoff;
}

void dg_process(dg_t *chain, float *const *channels, int32_t channelCount, int32_t frameCount) {
    struct dg_state *st = chain;
    if (!st || !channels || frameCount <= 0 || channelCount <= 0) return;
    // True bypass: not one sample is read or written. Checked before the parameter pickup, which is
    // safe because the latch is only ever 1 while every set of parameters published so far has been
    // a bypass set.
    if (atomic_load_explicit(&st->bypassLatch, memory_order_relaxed) != 0) return;

    dg_adopt_params(st);

    int32_t nch = channelCount < st->channels ? channelCount : st->channels;
    for (int32_t c = 0; c < nch; c++) {
        if (!channels[c]) { nch = c; break; }
    }
    if (nch <= 0) return;

    const dg_fp_mode_t fpMode = dg_fp_mode_begin();

    const int32_t satType = st->satType;
    const int32_t aaMode = st->aaMode;
    const int32_t mask = st->dlMask;
    const int32_t nominal = st->nominalDelay;
    const float crackleDecay = st->crackleDecay;
    const float rumbleCoef = st->rumbleCoef;
    const float rumbleGain = st->rumbleMakeup * DG_RUMBLE_RATIO;

    // Anti-alias coefficients follow the rate once per block, not once per frame; see the note on
    // smoothing in the header. The target rate wins over the smoothed one while a ramp is in
    // flight, because the smoothed value at the top of a block is still the *old* rate — keying off
    // it would leave the filter switched off for the whole block in which the decimator turns on,
    // which is exactly one block of unfiltered aliasing every time a preset is loaded.
    float aaRate = st->tgt[DG_S_RATEINC];
    if (!(aaRate > 0.0f)) aaRate = st->cur[DG_S_RATEINC];
    const int aaActive = (aaMode == DG_AA_FILTERED) && (aaRate > 0.0f);
    if (aaActive) {
        dg_update_aa(st, aaRate);
        if (!st->aaWasActive) {
            for (int32_t c = 0; c < st->channels; c++) memset(st->ch[c].aa, 0, sizeof(st->ch[c].aa));
        }
    }
    st->aaWasActive = aaActive;

    int32_t w = st->writeIndex;

    for (int32_t f = 0; f < frameCount; f++) {
        if (st->rampLeft > 0) {
            st->rampLeft--;
            if (st->rampLeft == 0) {
                memcpy(st->cur, st->tgt, sizeof(st->cur));
            } else {
                for (int32_t i = 0; i < DG_S_COUNT; i++) st->cur[i] += st->inc[i];
            }
        }

        const float bits = st->cur[DG_S_BITS];
        const float mu = st->cur[DG_S_MU];
        const float rateInc = st->cur[DG_S_RATEINC];
        const float drive = st->cur[DG_S_DRIVE];
        const float noise = st->cur[DG_S_NOISE];
        const float crackleP = st->cur[DG_S_CRACKLE];
        const float hfA = st->cur[DG_S_HFCOEF];
        const float mix = st->cur[DG_S_MIX];

        const int quantOn = bits < DG_BITS_OFF;
        const float steps = quantOn ? exp2f(bits - 1.0f) : 0.0f;
        const float muLog = (quantOn && mu > 0.0f) ? log1pf(mu) : 0.0f;
        const float muLogInv = muLog > 0.0f ? 1.0f / muLog : 0.0f;
        const int driveOn = (satType != DG_SAT_NONE) || (drive != 1.0f);
        const int decimateOn = rateInc > 0.0f && rateInc < 1.0f;
        const int noiseOn = noise > 0.0f || crackleP > 0.0f;
        const int hfOn = hfA < 1.0f;
        const int mixOn = mix < 1.0f;

        // Transport wobble. Both oscillators drive one delay line.
        float swing = 0.0f;
        if (st->cur[DG_S_WOWAMP] > 0.0f) {
            swing += st->cur[DG_S_WOWAMP] * sinf(st->wowPhase);
            st->wowPhase += st->cur[DG_S_WOWINC];
            if (st->wowPhase >= DG_TWO_PI) st->wowPhase -= DG_TWO_PI;
        }
        if (st->cur[DG_S_FLUTAMP] > 0.0f) {
            swing += st->cur[DG_S_FLUTAMP] * sinf(st->flutPhase);
            st->flutPhase += st->cur[DG_S_FLUTINC];
            if (st->flutPhase >= DG_TWO_PI) st->flutPhase -= DG_TWO_PI;
        }
        float delay = (float)nominal + swing;
        delay = dg_clampf(delay, 2.0f, (float)(st->dlLen - 4));
        const int32_t di = (int32_t)delay;
        const float frac = delay - (float)di;

        int latchNow = 0;
        if (decimateOn) {
            if (st->holdPhase >= 1.0f) {
                st->holdPhase -= 1.0f;
                latchNow = 1;
            }
            st->holdPhase += rateInc;
        } else {
            st->holdPhase = 1.0f;
        }

        for (int32_t c = 0; c < nch; c++) {
            dg_channel *ch = &st->ch[c];
            float *line = ch->delay;

            line[w] = channels[c][f];

            // Dry tap: an exact integer delay, so it is the input sample verbatim.
            const float dry = line[(w - nominal) & mask];

            // Wet tap: the same line read at the modulated position. At frac == 0 this returns the
            // stored sample exactly rather than through the polynomial, which is what keeps the
            // chain transparent when wow and flutter are both off.
            float y;
            if (frac == 0.0f) {
                y = line[(w - di) & mask];
            } else {
                const float a0 = line[(w - di + 1) & mask];
                const float a1 = line[(w - di) & mask];
                const float a2 = line[(w - di - 1) & mask];
                const float a3 = line[(w - di - 2) & mask];
                y = dg_hermite(a3, a2, a1, a0, 1.0f - frac);
            }

            if (driveOn) y = dg_saturate(y, drive, satType);

            if (decimateOn) {
                if (aaActive) {
                    for (int32_t s = 0; s < DG_AA_SECTIONS; s++) {
                        y = dg_biquad_tick(&st->aaCo[s], &ch->aa[s], y);
                    }
                }
                if (latchNow) ch->hold = y;
                y = ch->hold;
            }

            if (quantOn) y = dg_quantise(y, steps, mu, muLog, muLogInv);

            if (noiseOn) {
                uint64_t *rng = &ch->rng;
                // Hiss: the first difference of white, which tilts it up about 6 dB per octave —
                // the shape RIAA de-emphasis leaves behind, and close enough to tape hiss too.
                const float white = dg_rng_bipolar(rng);
                const float hiss = (white - ch->prevWhite) * 0.5f;
                ch->prevWhite = white;
                // Rumble: white through a 35 Hz one-pole, with makeup so the ratio means something.
                ch->rumble += rumbleCoef * (dg_rng_bipolar(rng) - ch->rumble);
                y += noise * (hiss + ch->rumble * rumbleGain);

                // Crackle: a Poisson process at crackleP per frame, heavy-tailed amplitude.
                if (crackleP > 0.0f && dg_rng_uniform(rng) < crackleP) {
                    for (int32_t v = 0; v < DG_CRACKLE_VOICES; v++) {
                        if (ch->crackle[v].env <= 1.0e-5f) {
                            const float u = dg_rng_uniform(rng);
                            const float u2 = u * u;
                            ch->crackle[v].amp = DG_CRACKLE_PEAK * (0.05f + 0.95f * u2 * u2);
                            ch->crackle[v].env = 1.0f;
                            break;
                        }
                    }
                }
                float burst = 0.0f;
                for (int32_t v = 0; v < DG_CRACKLE_VOICES; v++) {
                    if (ch->crackle[v].env > 1.0e-5f) {
                        burst += ch->crackle[v].amp * ch->crackle[v].env;
                        ch->crackle[v].env *= crackleDecay;
                    } else {
                        ch->crackle[v].env = 0.0f;
                    }
                }
                if (burst > 0.0f) y += burst * dg_rng_bipolar(rng);
            }

            if (hfOn) {
                ch->hf1 += hfA * (y - ch->hf1);
                ch->hf2 += hfA * (ch->hf1 - ch->hf2);
                y = ch->hf2;
            }

            channels[c][f] = mixOn ? (dry + (y - dry) * mix) : y;
        }

        w = (w + 1) & mask;
    }

    st->writeIndex = w;
    dg_fp_mode_end(fpMode);
}
