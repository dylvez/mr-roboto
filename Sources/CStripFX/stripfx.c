// See CStripFX.h for what is modelled and the thread model.

#include "CStripFX.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SFX_PARAM_SLOTS 4
#define SFX_ADOPT_ATTEMPTS 4
#define SFX_MAX_CHANNELS 8
/// How long a change of what is inserted takes to fade, each way.
#define SFX_FADE_MS 20.0
/// The horn's delay line: enough for the swing and the base delay at any rate up to 192 kHz.
#define SFX_HORN_LINE 1024
#define SFX_PI 3.14159265358979323846

// Rotors, in turns a second, and how long each takes to get most of the way to a new speed.
#define SFX_HORN_SLOW 0.83
#define SFX_HORN_FAST 6.8
#define SFX_DRUM_SLOW 0.67
#define SFX_DRUM_FAST 5.9
#define SFX_HORN_UP_S 0.4
#define SFX_HORN_DOWN_S 0.9
#define SFX_DRUM_UP_S 3.2
#define SFX_DRUM_DOWN_S 4.5
/// The horn's swing toward and away from a microphone, in seconds of delay.
#define SFX_HORN_SWING_S 0.00042
#define SFX_CROSSOVER_HZ 800.0
#define SFX_TIMELINE_SLOTS 3
/// The modulation's delay line, a power of two: 42 ms at 48 kHz, ten at 192, more than the
/// chorus's 5.4 ms and the flanger's 5.3.
#define SFX_MOD_LINE 2048
#define SFX_PHASER_STAGES 6
/// How often a moving corner's coefficients are worked out again, in samples.
#define SFX_CONTROL_EVERY 8

typedef struct { float b0, b1, b2, a1, a2; } sfx_co;
typedef struct { float z1, z2; } sfx_st;

static inline float sfx_run(const sfx_co *c, sfx_st *s, float x) {
    // Transposed direct form II.
    float y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return y;
}

// RBJ cookbook coefficients.
static sfx_co sfx_lowpass(double fs, double f, double q) {
    double w = 2 * SFX_PI * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a;
    return (sfx_co){ (float)((1 - c) / 2 / a0), (float)((1 - c) / a0), (float)((1 - c) / 2 / a0),
                     (float)(-2 * c / a0), (float)((1 - a) / a0) };
}
static sfx_co sfx_highpass(double fs, double f, double q) {
    double w = 2 * SFX_PI * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a;
    return (sfx_co){ (float)((1 + c) / 2 / a0), (float)(-(1 + c) / a0), (float)((1 + c) / 2 / a0),
                     (float)(-2 * c / a0), (float)((1 - a) / a0) };
}
static sfx_co sfx_peak(double fs, double f, double q, double gainDB) {
    double A = pow(10, gainDB / 40), w = 2 * SFX_PI * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a / A;
    return (sfx_co){ (float)((1 + a * A) / a0), (float)(-2 * c / a0), (float)((1 - a * A) / a0),
                     (float)(-2 * c / a0), (float)((1 - a / A) / a0) };
}
static sfx_co sfx_shelf(double fs, double f, double gainDB, int high) {
    double A = pow(10, gainDB / 40), w = 2 * SFX_PI * f / fs, c = cos(w), s = sin(w);
    double alpha = s / 2 * sqrt(2.0), sq = 2 * sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    if (high) {
        b0 = A * ((A + 1) + (A - 1) * c + sq); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - sq);
        a0 = (A + 1) - (A - 1) * c + sq; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - sq;
    } else {
        b0 = A * ((A + 1) - (A - 1) * c + sq); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - sq);
        a0 = (A + 1) + (A - 1) * c + sq; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - sq;
    }
    return (sfx_co){ (float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0), (float)(a1 / a0), (float)(a2 / a0) };
}

enum { AMP_HP, AMP_MID, AMP_LOWTILT, AMP_HIGHTILT, CAB_HP, CAB_BOX, CAB_PRESENCE, CAB_LP1, CAB_LP2, AMP_FILTERS };

typedef struct {
    sfx_st f[AMP_FILTERS];
    sfx_st aa1, aa2;      // the oversampled clip's anti-alias filter
    float prev;           // last input sample, for the interpolated half-step
} sfx_amp_channel;

typedef struct {
    sfx_st lp1, lp2, hp1, hp2;  // the crossover (Linkwitz–Riley, two Butterworths each way)
    float horn[SFX_HORN_LINE];
    int32_t write;
    float bright[SFX_MAX_CHANNELS];  // each microphone's one-pole on the horn
} sfx_rotary_state;

/// A stage's fade: what it is playing, and how much of it. A change of kind fades out, starts the
/// new one from rest, and fades it in, as the insert does.
typedef struct { int32_t kind; float wet; } sfx_stage;

/// A state-variable section's two integrators (Simper's trapezoidal form).
typedef struct { float ic1, ic2; } sfx_svf;
typedef struct { float a1, a2, a3, k; } sfx_svf_co;

typedef struct {
    float line[SFX_MOD_LINE];
    float ap[SFX_PHASER_STAGES];  // the phaser's all-passes
    float last;                   // the phaser's and the flanger's fed-back sample
    float tone;                   // the chorus's dark wet path, a one-pole
} sfx_mod_channel;

struct sfx_state {
    double sampleRate;
    int32_t channels;

    sfx_params_t slots[SFX_PARAM_SLOTS];
    _Atomic int64_t paramEpoch;
    int64_t paramEpochSeen;
    sfx_params_t active;           // what the audio thread is playing toward

    // What is sounding, and how much of it: fades to 0 before a change of kind, then back up.
    int32_t kind;
    float wet;
    float fadeStep;
    float level;                   // smoothed output gain

    // The amp, derived from `active` whenever it is adopted.
    sfx_co ampCo[AMP_FILTERS];
    sfx_co aaCo;
    float ampGain, ampBias, ampMakeup;
    sfx_amp_channel amp[SFX_MAX_CHANNELS];

    // The rotating speaker.
    sfx_co xLow, xHigh;
    sfx_rotary_state rot;
    double hornPhase, drumPhase;   // in turns
    double hornSpeed, drumSpeed;   // turns a second
    float growlGain, growlMakeup;

    // The pedal.
    sfx_stage pedal;
    sfx_svf pedalF[SFX_MAX_CHANNELS];
    sfx_svf_co pedalCo;
    float pedalEnv;                // the envelope filter's follower, on the sum
    double pedalPhase;             // the wah's foot when no clock says where the beat is, in turns

    // The modulation.
    sfx_stage mod;
    sfx_mod_channel modCh[SFX_MAX_CHANNELS];
    int32_t modWrite;
    double modPhase;               // in turns
    float modDepthNow;             // eased toward the asked depth, so a change never jumps the delay
    float phaserA;                 // the all-passes' coefficient as last worked out

    // The filter.
    sfx_stage filter;
    sfx_svf filtA[SFX_MAX_CHANNELS], filtB[SFX_MAX_CHANNELS];
    sfx_svf_co filtCoA, filtCoB;
    float corner;                  // Hz, as last played (eased, in octaves)
    float cornerCo;                // the corner the coefficients are for
    int32_t controlCount;

    // The pump.
    sfx_stage pump;
    float pumpGain;                // the gain it last applied

    // The song's clock and sections.
    sfx_timeline_t tlSlots[SFX_TIMELINE_SLOTS];
    _Atomic int64_t tlEpoch;
    int64_t tlEpochSeen;
    sfx_timeline_t tl;
    int32_t segmentHint;
};

static int64_t sfx_read_published(struct sfx_state *st, sfx_params_t *out) {
    int64_t epoch = atomic_load_explicit(&st->paramEpoch, memory_order_acquire);
    for (int attempt = 0; attempt < SFX_ADOPT_ATTEMPTS; attempt++) {
        *out = st->slots[(size_t)(epoch % SFX_PARAM_SLOTS)];
        atomic_thread_fence(memory_order_acquire);
        const int64_t after = atomic_load_explicit(&st->paramEpoch, memory_order_relaxed);
        if (after - epoch <= SFX_PARAM_SLOTS - 2) return epoch;
        epoch = after;
    }
    return -1;
}

static float sfx_clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

/// The amp's filters and gains for the active parameters. Owner-free: runs on the audio thread
/// when a set is adopted, and allocates nothing.
static void sfx_derive(struct sfx_state *st) {
    const double fs = st->sampleRate;
    const float drive = sfx_clampf(st->active.drive, 0, 1);
    const float tone = sfx_clampf(st->active.tone, 0, 1);
    st->ampCo[AMP_HP] = sfx_highpass(fs, 80, 0.707);
    // A driven preamp is pushed hardest in the middle, where the guitar is.
    st->ampCo[AMP_MID] = sfx_peak(fs, 800, 0.7, 6.0 * drive);
    st->ampCo[AMP_LOWTILT] = sfx_shelf(fs, 250, 3.0 * (0.5 - tone) * 2, 0);
    st->ampCo[AMP_HIGHTILT] = sfx_shelf(fs, 2500, 5.0 * (tone - 0.5) * 2, 1);
    st->ampCo[CAB_HP] = sfx_highpass(fs, 85, 0.707);
    st->ampCo[CAB_BOX] = sfx_peak(fs, 420, 1.0, -3.0);
    st->ampCo[CAB_PRESENCE] = sfx_peak(fs, 2200, 1.2, 3.0);
    st->ampCo[CAB_LP1] = sfx_lowpass(fs, 5200, 0.54);
    st->ampCo[CAB_LP2] = sfx_lowpass(fs, 5200, 1.31);
    st->aaCo = sfx_lowpass(fs * 2, fs * 0.45, 0.707);
    // Up to +36 dB into the clip; what comes out is brought back near the level that went in.
    st->ampGain = 1.0f + 62.0f * drive * drive;
    st->ampBias = 0.25f * drive;
    st->ampMakeup = powf(st->ampGain, -0.62f) * 1.25f;
    const float growl = sfx_clampf(st->active.growl, 0, 1);
    st->growlGain = 1.0f + 9.0f * growl * growl;
    st->growlMakeup = powf(st->growlGain, -0.6f);
}

static void sfx_adopt(struct sfx_state *st, int fade) {
    if (atomic_load_explicit(&st->paramEpoch, memory_order_acquire) == st->paramEpochSeen) return;
    sfx_params_t published;
    const int64_t epoch = sfx_read_published(st, &published);
    if (epoch < 0) return;
    st->active = published;
    st->paramEpochSeen = epoch;
    sfx_derive(st);
    if (!fade) {
        st->kind = published.kind;
        st->wet = published.kind == SFX_OFF ? 0.0f : 1.0f;
        st->level = published.level;
    }
}

static const sfx_params_t sfx_off_params = {
    .kind = SFX_OFF, .drive = 0.3f, .tone = 0.5f, .fast = 0.0f, .growl = 0.0f, .level = 1.0f,
    .pedal = SFX_PEDAL_OFF, .pedalAmount = 0.5f, .pedalResonance = 0.6f, .pedalBeats = 0.5f,
    .mod = SFX_MOD_OFF, .modRate = 0.5f, .modDepth = 0.5f, .modFeedback = 0.0f,
    .filter = SFX_FILTER_OFF, .filterHz = 20000.0f, .filterResonance = 0.0f,
    .pump = 0, .pumpDB = 6.0f, .pumpReleaseBeats = 0.5f,
};

/// The stages' kinds taken from the active parameters at once, with no fade: a fresh start.
static void sfx_settle_stages(struct sfx_state *st) {
    st->pedal = (sfx_stage){ st->active.pedal, st->active.pedal != SFX_PEDAL_OFF ? 1.0f : 0.0f };
    st->mod = (sfx_stage){ st->active.mod, st->active.mod != SFX_MOD_OFF ? 1.0f : 0.0f };
    st->filter = (sfx_stage){ st->active.filter, st->active.filter != SFX_FILTER_OFF ? 1.0f : 0.0f };
    st->pump = (sfx_stage){ st->active.pump, st->active.pump ? 1.0f : 0.0f };
    st->modDepthNow = st->active.modDepth;
}

static void sfx_adopt_timeline(struct sfx_state *st) {
    int64_t epoch = atomic_load_explicit(&st->tlEpoch, memory_order_acquire);
    if (epoch == st->tlEpochSeen) return;
    for (int attempt = 0; attempt < SFX_ADOPT_ATTEMPTS; attempt++) {
        memcpy(&st->tl, &st->tlSlots[(size_t)(epoch % SFX_TIMELINE_SLOTS)], sizeof(sfx_timeline_t));
        atomic_thread_fence(memory_order_acquire);
        const int64_t after = atomic_load_explicit(&st->tlEpoch, memory_order_relaxed);
        if (after - epoch <= SFX_TIMELINE_SLOTS - 2) {
            st->tlEpochSeen = epoch;
            st->segmentHint = 0;
            if (st->tl.count > SFX_SEGMENTS) st->tl.count = SFX_SEGMENTS;
            if (st->tl.count < 0) st->tl.count = 0;
            return;
        }
        epoch = after;
    }
}

sfx_t *sfx_create(double sampleRate, int32_t channels) {
    if (!(sampleRate > 0.0) || channels <= 0 || channels > SFX_MAX_CHANNELS) return NULL;
    struct sfx_state *st = (struct sfx_state *)calloc(1, sizeof(struct sfx_state));
    if (!st) return NULL;
    st->sampleRate = sampleRate;
    st->channels = channels;
    st->fadeStep = (float)(1.0 / (SFX_FADE_MS * 0.001 * sampleRate));
    st->xLow = sfx_lowpass(sampleRate, SFX_CROSSOVER_HZ, 0.707);
    st->xHigh = sfx_highpass(sampleRate, SFX_CROSSOVER_HZ, 0.707);
    st->slots[0] = sfx_off_params;
    st->active = sfx_off_params;
    st->level = 1.0f;
    atomic_store_explicit(&st->paramEpoch, 0, memory_order_relaxed);
    st->paramEpochSeen = 0;
    // Slot 0 of the timeline is all zeros: not valid, nothing keeps time.
    atomic_store_explicit(&st->tlEpoch, 0, memory_order_relaxed);
    st->tlEpochSeen = -1;
    sfx_derive(st);
    sfx_reset(st);
    return st;
}

void sfx_destroy(sfx_t *fx) { free(fx); }

void sfx_reset(sfx_t *fx) {
    struct sfx_state *st = fx;
    if (!st) return;
    memset(st->amp, 0, sizeof(st->amp));
    memset(&st->rot, 0, sizeof(st->rot));
    memset(st->pedalF, 0, sizeof(st->pedalF));
    memset(st->modCh, 0, sizeof(st->modCh));
    memset(st->filtA, 0, sizeof(st->filtA));
    memset(st->filtB, 0, sizeof(st->filtB));
    st->pedalEnv = 0;
    st->pedalPhase = 0;
    st->modWrite = 0;
    st->modPhase = 0;
    st->phaserA = 0;
    st->controlCount = 0;
    st->pumpGain = 1.0f;
    st->paramEpochSeen = -1;
    sfx_adopt(st, 0);
    sfx_adopt_timeline(st);
    sfx_settle_stages(st);
    st->corner = st->active.filterHz > 20.0f ? st->active.filterHz : 20000.0f;
    st->cornerCo = -1.0f;
    st->hornPhase = 0;
    st->drumPhase = 0.25;  // the drum's baffle a quarter turn from the horn's mouth
    const int fast = st->active.fast >= 0.5f;
    st->hornSpeed = fast ? SFX_HORN_FAST : SFX_HORN_SLOW;
    st->drumSpeed = fast ? SFX_DRUM_FAST : SFX_DRUM_SLOW;
}

void sfx_set_params(sfx_t *fx, const sfx_params_t *params) {
    struct sfx_state *st = fx;
    if (!st || !params) return;
    const int64_t epoch = atomic_load_explicit(&st->paramEpoch, memory_order_relaxed) + 1;
    st->slots[(size_t)(epoch % SFX_PARAM_SLOTS)] = *params;
    atomic_store_explicit(&st->paramEpoch, epoch, memory_order_release);
}

void sfx_set_timeline(sfx_t *fx, const sfx_timeline_t *timeline) {
    struct sfx_state *st = fx;
    if (!st || !timeline) return;
    const int64_t epoch = atomic_load_explicit(&st->tlEpoch, memory_order_relaxed) + 1;
    memcpy(&st->tlSlots[(size_t)(epoch % SFX_TIMELINE_SLOTS)], timeline, sizeof(sfx_timeline_t));
    atomic_store_explicit(&st->tlEpoch, epoch, memory_order_release);
}

void sfx_rotor_speeds(const sfx_t *fx, float *horn, float *drum) {
    if (!fx) return;
    if (horn) *horn = (float)fx->hornSpeed;
    if (drum) *drum = (float)fx->drumSpeed;
}

float sfx_filter_corner(const sfx_t *fx) {
    if (!fx || fx->filter.kind == SFX_FILTER_OFF) return 0.0f;
    return fx->corner;
}


static inline float sfx_clip(float u, float bias) {
    return tanhf(u + bias) - tanhf(bias);
}

/// One sample of the amp, on one channel.
static inline float sfx_amp_sample(struct sfx_state *st, sfx_amp_channel *ch, float x) {
    x = sfx_run(&st->ampCo[AMP_HP], &ch->f[AMP_HP], x);
    x = sfx_run(&st->ampCo[AMP_MID], &ch->f[AMP_MID], x);
    // Twice the rate through the clip: the half-step between samples, then the sample.
    const float half = 0.5f * (ch->prev + x);
    ch->prev = x;
    float y0 = sfx_clip(st->ampGain * half, st->ampBias);
    float y1 = sfx_clip(st->ampGain * x, st->ampBias);
    y0 = sfx_run(&st->aaCo, &ch->aa2, sfx_run(&st->aaCo, &ch->aa1, y0));
    y1 = sfx_run(&st->aaCo, &ch->aa2, sfx_run(&st->aaCo, &ch->aa1, y1));
    float y = y1 * st->ampMakeup;
    y = sfx_run(&st->ampCo[AMP_LOWTILT], &ch->f[AMP_LOWTILT], y);
    y = sfx_run(&st->ampCo[AMP_HIGHTILT], &ch->f[AMP_HIGHTILT], y);
    y = sfx_run(&st->ampCo[CAB_HP], &ch->f[CAB_HP], y);
    y = sfx_run(&st->ampCo[CAB_BOX], &ch->f[CAB_BOX], y);
    y = sfx_run(&st->ampCo[CAB_PRESENCE], &ch->f[CAB_PRESENCE], y);
    y = sfx_run(&st->ampCo[CAB_LP1], &ch->f[CAB_LP1], y);
    return sfx_run(&st->ampCo[CAB_LP2], &ch->f[CAB_LP2], y);
}

/// The rotors eased toward their target speed over one block, by the time constant of each.
static void sfx_ease_rotors(struct sfx_state *st, int32_t frames) {
    const int fast = st->active.fast >= 0.5f;
    const double hornTarget = fast ? SFX_HORN_FAST : SFX_HORN_SLOW;
    const double drumTarget = fast ? SFX_DRUM_FAST : SFX_DRUM_SLOW;
    const double seconds = frames / st->sampleRate;
    const double hornTau = hornTarget > st->hornSpeed ? SFX_HORN_UP_S : SFX_HORN_DOWN_S;
    const double drumTau = drumTarget > st->drumSpeed ? SFX_DRUM_UP_S : SFX_DRUM_DOWN_S;
    st->hornSpeed += (hornTarget - st->hornSpeed) * (1.0 - exp(-seconds / hornTau));
    st->drumSpeed += (drumTarget - st->drumSpeed) * (1.0 - exp(-seconds / drumTau));
}

// MARK: - The stages around the insert

/// One step of a stage's fade toward `wanted`. True when it has just switched kind, so the
/// caller starts the new one from rest.
static inline int sfx_stage_step(sfx_stage *s, int32_t wanted, float step) {
    if (s->kind != wanted) {
        s->wet -= step;
        if (s->wet <= 0.0f) {
            s->wet = 0.0f;
            s->kind = wanted;
            return 1;
        }
    } else if (s->kind != 0 && s->wet < 1.0f) {
        s->wet += step;
        if (s->wet > 1.0f) s->wet = 1.0f;
    }
    return 0;
}

static inline int sfx_stage_idle(const sfx_stage *s, int32_t wanted) {
    return s->kind == 0 && s->wet <= 0.0f && wanted == 0;
}

static sfx_svf_co sfx_svf_coeffs(double fs, double f, double k) {
    const double g = tan(SFX_PI * f / fs);
    const double a1 = 1.0 / (1.0 + g * (g + k));
    return (sfx_svf_co){ (float)a1, (float)(g * a1), (float)(g * g * a1), (float)k };
}

/// One sample through a state-variable section: its low-pass and band-pass outputs.
static inline void sfx_svf_run(const sfx_svf_co *c, sfx_svf *s, float x, float *low, float *band) {
    const float v3 = x - s->ic2;
    const float v1 = c->a1 * s->ic1 + c->a2 * v3;
    const float v2 = s->ic2 + c->a2 * s->ic1 + c->a3 * v3;
    s->ic1 = 2.0f * v1 - s->ic1;
    s->ic2 = 2.0f * v2 - s->ic2;
    *low = v2;
    *band = v1;
}

static inline float sfx_clamp_corner(const struct sfx_state *st, float hz) {
    const float top = (float)(st->sampleRate * 0.45);
    return hz < 20.0f ? 20.0f : (hz > top ? top : hz);
}

/// A triangle, −1 … 1, of a phase in turns.
static inline float sfx_triangle(double phase) {
    const double p = phase - floor(phase);
    return (float)(4.0 * fabs(p - floor(p + 0.5)) - 1.0);
}

static inline float sfx_read_line(const float *line, int32_t write, float delay) {
    const float read = (float)write - delay;
    const int32_t i0 = (int32_t)floorf(read);
    const float frac = read - (float)i0;
    const float a = line[(i0 + 4 * SFX_MOD_LINE) & (SFX_MOD_LINE - 1)];
    const float b = line[(i0 + 1 + 4 * SFX_MOD_LINE) & (SFX_MOD_LINE - 1)];
    return a + (b - a) * frac;
}

/// The section the song is in at `beat` (in the form's own beats), or NULL.
static const sfx_segment_t *sfx_segment(struct sfx_state *st, double beat) {
    const int32_t count = st->tl.count;
    if (count <= 0) return NULL;
    const int32_t hint = st->segmentHint;
    if (hint >= 0 && hint < count) {
        const sfx_segment_t *s = &st->tl.segments[hint];
        if (beat >= s->startBeat && beat < (double)s->startBeat + s->lengthBeats) return s;
    }
    for (int32_t k = 0; k < count; k++) {
        const sfx_segment_t *s = &st->tl.segments[k];
        if (beat >= s->startBeat && beat < (double)s->startBeat + s->lengthBeats) {
            st->segmentHint = k;
            return s;
        }
    }
    return NULL;
}

/// How far the pump has the strip down at `beat`, dB: the deeper of the dips the last two
/// triggers left, each down in two milliseconds and back on an exponential.
static float sfx_pump_dip(const struct sfx_state *st, const sfx_segment_t *seg, double beat, double secondsPerBeat) {
    if (!seg || seg->count <= 0 || seg->patternBeats <= 0.0f) return 0.0f;
    const float depth = seg->pumpDB >= 0.0f ? seg->pumpDB : st->active.pumpDB;
    if (!(depth > 0.0f)) return 0.0f;
    const double into = beat - seg->startBeat;
    const double pattern = seg->patternBeats;
    const double pass = floor(into / pattern);
    double last = -1e9, prev = -1e9;
    const int32_t count = seg->count < SFX_TRIGGERS ? seg->count : SFX_TRIGGERS;
    for (int32_t k = 0; k < count; k++) {
        for (int back = 0; back < 2; back++) {
            const double x = (pass - back) * pattern + seg->at[k];
            if (x < 0.0 || x > into) continue;
            if (x > last) { prev = last; last = x; } else if (x > prev) { prev = x; }
        }
    }
    if (last < -1e8) return 0.0f;
    const double attack = 0.002;
    double release = st->active.pumpReleaseBeats * secondsPerBeat / 3.0;
    if (release < 0.005) release = 0.005;
    double dip = 0.0;
    for (int which = 0; which < 2; which++) {
        const double at = which == 0 ? last : prev;
        if (at < -1e8) continue;
        const double t = (into - at) * secondsPerBeat;
        const double d = t < attack ? depth * t / attack : depth * exp(-(t - attack) / release);
        if (d > dip) dip = d;
    }
    return (float)dip;
}

void sfx_process(sfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames) {
    sfx_process_at(fx, channels, channelCount, frames, -1.0);
}

void sfx_process_at(sfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames, double sampleTime) {
    struct sfx_state *st = fx;
    if (!st || !channels || frames <= 0) return;
    sfx_adopt(st, 1);
    sfx_adopt_timeline(st);
    const int32_t n = channelCount < st->channels ? channelCount : st->channels;
    if (n <= 0) return;
    const sfx_params_t *p = &st->active;

    // A change of kind: fade out what is sounding, then switch to the new one from silence.
    const int32_t wanted = p->kind;
    const int insertIdle = st->kind == SFX_OFF && st->wet <= 0.0f && wanted == SFX_OFF;
    const int pedalIdle = sfx_stage_idle(&st->pedal, p->pedal);
    const int modIdle = sfx_stage_idle(&st->mod, p->mod);
    const int filterIdle = sfx_stage_idle(&st->filter, p->filter);
    const int pumpIdle = sfx_stage_idle(&st->pump, p->pump ? 1 : 0);
    if (insertIdle && pedalIdle && modIdle && filterIdle && pumpIdle) return;  // off, and settled

    if (st->kind == SFX_ROTARY || wanted == SFX_ROTARY) sfx_ease_rotors(st, frames);
    const float levelTarget = st->active.level;
    const float levelStep = (levelTarget - st->level) / (float)frames;
    const double fs = st->sampleRate;
    const float swing = (float)(SFX_HORN_SWING_S * fs);
    const float baseDelay = swing + 4.0f;
    const double hornInc = st->hornSpeed / fs, drumInc = st->drumSpeed / fs;

    // The song's clock, when there is one; 120 to the minute when there is not.
    const int clocked = sampleTime >= 0.0 && st->tl.valid && st->tl.samplesPerBeat > 0.0;
    const double samplesPerBeat = clocked ? st->tl.samplesPerBeat : fs * 0.5;
    const double secondsPerBeat = samplesPerBeat / fs;
    const double cycle = clocked ? st->tl.cycleBeats : 0.0;

    // Easing constants.
    const float depthEase = 1.0f - expf(-1.0f / (0.02f * (float)fs));
    const float cornerEase = 1.0f - expf(-(float)SFX_CONTROL_EVERY / (0.008f * (float)fs));
    const float envAttack = 1.0f - expf(-1.0f / (0.004f * (float)fs));
    const float envRelease = 1.0f - expf(-1.0f / (0.15f * (float)fs));
    const float chorusTone = 1.0f - expf(-2.0f * (float)SFX_PI * 7000.0f / (float)fs);

    float v[SFX_MAX_CHANNELS];
    for (int32_t i = 0; i < frames; i++) {
        for (int32_t c = 0; c < n; c++) v[c] = channels[c][i];

        // Where the song is.
        double beat = -1.0;
        const sfx_segment_t *seg = NULL;
        if (clocked) {
            beat = (sampleTime + (double)i - st->tl.origin) / samplesPerBeat;
            if (beat >= 0.0) {
                if (cycle > 0.0) beat = fmod(beat, cycle);
                seg = sfx_segment(st, beat);
            }
        }
        const int control = st->controlCount == 0;
        st->controlCount = (st->controlCount + 1) % SFX_CONTROL_EVERY;

        // The pedal.
        if (!pedalIdle) {
            if (sfx_stage_step(&st->pedal, p->pedal, st->fadeStep)) {
                memset(st->pedalF, 0, sizeof(st->pedalF));
                st->pedalEnv = 0;
            }
            if (st->pedal.kind != SFX_PEDAL_OFF) {
                if (st->pedal.kind == SFX_PEDAL_ENVELOPE) {
                    float m = 0.0f;
                    for (int32_t c = 0; c < n; c++) m += v[c];
                    m = fabsf(m / (float)n);
                    st->pedalEnv += (m > st->pedalEnv ? envAttack : envRelease) * (m - st->pedalEnv);
                } else if (!clocked) {
                    st->pedalPhase += 1.0 / (samplesPerBeat * (p->pedalBeats > 0.05f ? p->pedalBeats : 0.5f));
                }
                if (control) {
                    float corner;
                    const float amount = sfx_clampf(p->pedalAmount, 0, 1);
                    if (st->pedal.kind == SFX_PEDAL_ENVELOPE) {
                        const float open = sfx_clampf(st->pedalEnv * (2.0f + 18.0f * amount), 0, 1);
                        corner = 200.0f * powf(2.0f, 4.0f * open);
                    } else {
                        const double turns = clocked ? beat / (p->pedalBeats > 0.05f ? p->pedalBeats : 0.5f) : st->pedalPhase;
                        const float foot = (float)(0.5 - 0.5 * cos(2.0 * SFX_PI * turns));
                        corner = 350.0f * powf(2.0f, 2.7f * foot * (0.4f + 0.6f * amount));
                    }
                    const double k = 1.0 - 0.85 * sfx_clampf(p->pedalResonance, 0, 1);
                    st->pedalCo = sfx_svf_coeffs(fs, sfx_clamp_corner(st, corner), k);
                }
                const float wet = st->pedal.wet;
                for (int32_t c = 0; c < n; c++) {
                    float low, band;
                    sfx_svf_run(&st->pedalCo, &st->pedalF[c], v[c], &low, &band);
                    // The envelope filter is a resonant low-pass opening and closing; the wah a
                    // band-pass with a little of what is under it.
                    const float y = st->pedal.kind == SFX_PEDAL_ENVELOPE
                        ? low + 0.5f * st->pedalCo.k * band
                        : 1.6f * st->pedalCo.k * band + 0.35f * low;
                    v[c] += (y - v[c]) * wet;
                }
            }
        }

        // The insert.
        if (st->kind != wanted) {
            st->wet -= st->fadeStep;
            if (st->wet <= 0.0f) {
                st->wet = 0.0f;
                st->kind = wanted;
                memset(st->amp, 0, sizeof(st->amp));
                memset(&st->rot, 0, sizeof(st->rot));
            }
        } else if (st->kind != SFX_OFF && st->wet < 1.0f) {
            st->wet += st->fadeStep;
            if (st->wet > 1.0f) st->wet = 1.0f;
        }
        st->level += levelStep;
        const float wet = st->wet;

        if (st->kind == SFX_AMP) {
            for (int32_t c = 0; c < n; c++) {
                const float dry = v[c];
                const float y = sfx_amp_sample(st, &st->amp[c], dry) * st->level;
                v[c] = dry + (y - dry) * wet;
            }
        } else if (st->kind == SFX_ROTARY) {
            // One speaker, fed the sum.
            float m = 0.0f;
            for (int32_t c = 0; c < n; c++) m += v[c];
            m /= (float)n;
            if (st->growlGain > 1.0f) m = tanhf(m * st->growlGain) * st->growlMakeup;
            float low = sfx_run(&st->xLow, &st->rot.lp2, sfx_run(&st->xLow, &st->rot.lp1, m));
            float high = sfx_run(&st->xHigh, &st->rot.hp2, sfx_run(&st->xHigh, &st->rot.hp1, m));
            st->rot.horn[st->rot.write] = high;
            const double horn = 2 * SFX_PI * st->hornPhase, drum = 2 * SFX_PI * st->drumPhase;
            for (int32_t c = 0; c < n; c++) {
                // Microphones a third of a turn apart, either side of the front.
                const double place = n == 1 ? 0.0 : (2 * SFX_PI / 3) * ((double)c / (double)(n - 1) - 0.5);
                const float facing = (float)cos(horn + place);
                // Nearer when it faces the microphone: less delay, so the pitch rises as it comes.
                const float delay = baseDelay - swing * (float)sin(horn + place);
                const float read = (float)st->rot.write - delay;
                const int32_t i0 = (int32_t)floorf(read);
                const float frac = read - (float)i0;
                const float a = st->rot.horn[(i0 + SFX_HORN_LINE) & (SFX_HORN_LINE - 1)];
                const float b = st->rot.horn[(i0 + 1 + SFX_HORN_LINE) & (SFX_HORN_LINE - 1)];
                float h = a + (b - a) * frac;
                // Brighter facing the microphone, duller turned away: a one-pole between 2.5 and 10 kHz.
                const float corner = 2500.0f + 7500.0f * (0.5f + 0.5f * facing);
                const float k = 1.0f - expf(-2.0f * (float)SFX_PI * corner / (float)fs);
                st->rot.bright[c] += k * (h - st->rot.bright[c]);
                h = st->rot.bright[c] * (0.68f + 0.32f * facing);
                const float d = low * (0.82f + 0.18f * (float)cos(drum + place));
                const float y = (h + d) * 1.22f * st->level;
                v[c] = v[c] + (y - v[c]) * wet;
            }
            st->rot.write = (st->rot.write + 1) & (SFX_HORN_LINE - 1);
            st->hornPhase += hornInc;
            if (st->hornPhase >= 1.0) st->hornPhase -= 1.0;
            st->drumPhase += drumInc;
            if (st->drumPhase >= 1.0) st->drumPhase -= 1.0;
        }

        // The modulation.
        if (!modIdle) {
            if (sfx_stage_step(&st->mod, p->mod, st->fadeStep)) {
                memset(st->modCh, 0, sizeof(st->modCh));
                st->modPhase = 0;
            }
            if (st->mod.kind != SFX_MOD_OFF) {
                st->modDepthNow += depthEase * (sfx_clampf(p->modDepth, 0, 1) - st->modDepthNow);
                const float depth = st->modDepthNow;
                const float feedback = sfx_clampf(p->modFeedback, 0, 0.9f);
                const int32_t w = st->modWrite;
                const int kind = st->mod.kind;
                if (kind == SFX_MOD_PHASER && control) {
                    const double s = 0.5 + 0.5 * sin(2 * SFX_PI * st->modPhase);
                    const double f = 600.0 * pow(2.0, (s - 0.5) * 3.6 * depth);
                    const double t = tan(SFX_PI * sfx_clamp_corner(st, (float)f) / fs);
                    st->phaserA = (float)((t - 1.0) / (t + 1.0));
                }
                const float modWet = st->mod.wet;
                for (int32_t c = 0; c < n; c++) {
                    sfx_mod_channel *m = &st->modCh[c];
                    const float x = v[c];
                    float y = x;
                    if (kind == SFX_MOD_CHORUS || kind == SFX_MOD_VIBRATO) {
                        m->line[w] = x;
                        float ms;
                        if (kind == SFX_MOD_CHORUS) {
                            // The two sides swept against each other: what makes it wide.
                            ms = 3.5f + 1.85f * depth * sfx_triangle(st->modPhase + (c % 2 ? 0.5 : 0.0));
                        } else {
                            ms = 2.0f + 1.4f * depth * (float)sin(2 * SFX_PI * st->modPhase);
                        }
                        const float wetSample = sfx_read_line(m->line, w, ms * 0.001f * (float)fs);
                        if (kind == SFX_MOD_CHORUS) {
                            m->tone += chorusTone * (wetSample - m->tone);
                            y = 0.62f * (x + m->tone);
                        } else {
                            y = wetSample;
                        }
                    } else if (kind == SFX_MOD_FLANGER) {
                        m->line[w] = x + feedback * m->last;
                        const float ms = 0.3f + 4.7f * depth * (0.5f + 0.5f * sfx_triangle(st->modPhase + (c % 2 ? 0.25 : 0.0)));
                        const float wetSample = sfx_read_line(m->line, w, ms * 0.001f * (float)fs);
                        m->last = wetSample;
                        y = 0.65f * (x + wetSample);
                    } else if (kind == SFX_MOD_PHASER) {
                        const float a = st->phaserA;
                        float u = x + feedback * m->last;
                        for (int s = 0; s < SFX_PHASER_STAGES; s++) {
                            const float out = a * u + m->ap[s];
                            m->ap[s] = u - a * out;
                            u = out;
                        }
                        m->last = u;
                        y = 0.65f * (x + u);
                    }
                    v[c] = x + (y - x) * modWet;
                }
                st->modWrite = (w + 1) & (SFX_MOD_LINE - 1);
                st->modPhase += (double)sfx_clampf(p->modRate, 0.01f, 20.0f) / fs;
                if (st->modPhase >= 1.0) st->modPhase -= 1.0;
            }
        }

        // The filter.
        if (!filterIdle) {
            if (sfx_stage_step(&st->filter, p->filter, st->fadeStep)) {
                memset(st->filtA, 0, sizeof(st->filtA));
                memset(st->filtB, 0, sizeof(st->filtB));
                st->cornerCo = -1.0f;
            }
            if (st->filter.kind != SFX_FILTER_OFF) {
                if (control) {
                    float target = p->filterHz;
                    if (seg && seg->filterFrom > 0.0f) {
                        const float from = seg->filterFrom, to = seg->filterTo;
                        if (to > 0.0f && fabsf(to - from) > 0.5f && seg->lengthBeats > 0.0f) {
                            double u = (beat - seg->startBeat) / seg->lengthBeats;
                            u = u < 0 ? 0 : (u > 1 ? 1 : u);
                            target = from * powf(to / from, (float)u);
                        } else {
                            target = from;
                        }
                    }
                    target = sfx_clamp_corner(st, target);
                    const float now = sfx_clamp_corner(st, st->corner);
                    st->corner = expf(logf(now) + (logf(target) - logf(now)) * cornerEase);
                    if (st->cornerCo <= 0.0f || fabsf(st->corner - st->cornerCo) > 0.001f * st->cornerCo) {
                        const double resonance = sfx_clampf(p->filterResonance, 0, 1);
                        st->filtCoA = sfx_svf_coeffs(fs, st->corner, 1.8478);
                        st->filtCoB = sfx_svf_coeffs(fs, st->corner, 0.7654 * (1.0 - 0.85 * resonance));
                        st->cornerCo = st->corner;
                    }
                }
                const float filterWet = st->filter.wet;
                const int low = st->filter.kind == SFX_FILTER_LOWPASS;
                for (int32_t c = 0; c < n; c++) {
                    const float x = v[c];
                    float l, b;
                    sfx_svf_run(&st->filtCoA, &st->filtA[c], x, &l, &b);
                    const float y1 = low ? l : x - st->filtCoA.k * b - l;
                    sfx_svf_run(&st->filtCoB, &st->filtB[c], y1, &l, &b);
                    const float y = low ? l : y1 - st->filtCoB.k * b - l;
                    v[c] = x + (y - x) * filterWet;
                }
            }
        }

        // The pump.
        if (!pumpIdle) {
            sfx_stage_step(&st->pump, p->pump ? 1 : 0, st->fadeStep);
            const float dip = st->pump.kind ? sfx_pump_dip(st, seg, beat, secondsPerBeat) : 0.0f;
            const float gain = dip > 0.0f ? powf(10.0f, -dip / 20.0f) : 1.0f;
            st->pumpGain = gain;
            const float g = 1.0f + (gain - 1.0f) * st->pump.wet;
            for (int32_t c = 0; c < n; c++) v[c] *= g;
        }

        for (int32_t c = 0; c < n; c++) channels[c][i] = v[c];
    }
    st->level = levelTarget;
}
