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

sfx_t *sfx_create(double sampleRate, int32_t channels) {
    if (!(sampleRate > 0.0) || channels <= 0 || channels > SFX_MAX_CHANNELS) return NULL;
    struct sfx_state *st = (struct sfx_state *)calloc(1, sizeof(struct sfx_state));
    if (!st) return NULL;
    st->sampleRate = sampleRate;
    st->channels = channels;
    st->fadeStep = (float)(1.0 / (SFX_FADE_MS * 0.001 * sampleRate));
    st->xLow = sfx_lowpass(sampleRate, SFX_CROSSOVER_HZ, 0.707);
    st->xHigh = sfx_highpass(sampleRate, SFX_CROSSOVER_HZ, 0.707);
    sfx_params_t off = { SFX_OFF, 0.3f, 0.5f, 0.0f, 0.0f, 1.0f };
    st->slots[0] = off;
    st->active = off;
    st->level = 1.0f;
    atomic_store_explicit(&st->paramEpoch, 0, memory_order_relaxed);
    st->paramEpochSeen = 0;
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
    st->paramEpochSeen = -1;
    sfx_adopt(st, 0);
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

void sfx_rotor_speeds(const sfx_t *fx, float *horn, float *drum) {
    if (!fx) return;
    if (horn) *horn = (float)fx->hornSpeed;
    if (drum) *drum = (float)fx->drumSpeed;
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

void sfx_process(sfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames) {
    struct sfx_state *st = fx;
    if (!st || !channels || frames <= 0) return;
    sfx_adopt(st, 1);
    const int32_t n = channelCount < st->channels ? channelCount : st->channels;
    if (n <= 0) return;

    // A change of kind: fade out what is sounding, then switch to the new one from silence.
    const int32_t wanted = st->active.kind;
    if (st->kind == SFX_OFF && st->wet <= 0.0f && wanted == SFX_OFF) return;  // off, and settled

    if (st->kind == SFX_ROTARY || wanted == SFX_ROTARY) sfx_ease_rotors(st, frames);
    const float levelTarget = st->active.level;
    const float levelStep = (levelTarget - st->level) / (float)frames;
    const double fs = st->sampleRate;
    const float swing = (float)(SFX_HORN_SWING_S * fs);
    const float baseDelay = swing + 4.0f;
    const double hornInc = st->hornSpeed / fs, drumInc = st->drumSpeed / fs;

    for (int32_t i = 0; i < frames; i++) {
        // The fade.
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
                const float dry = channels[c][i];
                const float y = sfx_amp_sample(st, &st->amp[c], dry) * st->level;
                channels[c][i] = dry + (y - dry) * wet;
            }
        } else if (st->kind == SFX_ROTARY) {
            // One speaker, fed the sum.
            float m = 0.0f;
            for (int32_t c = 0; c < n; c++) m += channels[c][i];
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
                channels[c][i] = channels[c][i] + (y - channels[c][i]) * wet;
            }
            st->rot.write = (st->rot.write + 1) & (SFX_HORN_LINE - 1);
            st->hornPhase += hornInc;
            if (st->hornPhase >= 1.0) st->hornPhase -= 1.0;
            st->drumPhase += drumInc;
            if (st->drumPhase >= 1.0) st->drumPhase -= 1.0;
        } else if (wet <= 0.0f && st->kind == SFX_OFF) {
            // Settled off mid-block: nothing more to do in it.
            break;
        }
    }
    st->level = levelTarget;
}
