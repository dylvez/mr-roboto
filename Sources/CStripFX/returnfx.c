// The returns' own effects: a spring, a gated room, a tape echo. See CStripFX.h for what each
// models; the thread model is the strip insert's (owner thread sets, audio thread processes).

#include "CStripFX.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RFX_PARAM_SLOTS 4
#define RFX_ADOPT_ATTEMPTS 4
#define RFX_FADE_MS 20.0
#define RFX_PI 3.14159265358979323846

// The spring: two a side, the dispersion's all-passes stretched to put the chirp under 4.4 kHz.
#define RFX_SPRINGS 4
#define RFX_SPRING_STAGES 80
#define RFX_STRETCH_MAX 32
#define RFX_SPRING_TRANSITION_HZ 4400.0
#define RFX_SPRING_A 0.7f

// The gated room.
#define RFX_FDN 4
#define RFX_DIFFUSERS 4

// The tape: the longest gap between repeats, seconds.
#define RFX_TAPE_SECONDS 4.5

typedef struct {
    // Each stage keeps its last K inputs and outputs: y[n] = a x[n] + x[n-K] - a y[n-K].
    float x[RFX_SPRING_STAGES][RFX_STRETCH_MAX];
    float y[RFX_SPRING_STAGES][RFX_STRETCH_MAX];
    int32_t at;        // where in the K-long rings this sample goes
    float *line;       // the trip down the spring
    int32_t lineLength, write, delay;
    float lp1, lp2, hp, hpIn;  // the loop's darkening and thinning
    float back;        // what came round last time, filtered
} rfx_spring;

typedef struct {
    float *line;
    int32_t length, write;
    float damp;
} rfx_fdn_line;

typedef struct {
    float *line;
    int32_t length, write;
} rfx_diffuser;

typedef struct {
    float *line;
    int32_t length, write;
    float hp, hpIn, lp1, lp2;
} rfx_tape_channel;

struct rfx_state {
    double sampleRate;
    int32_t channels;

    rfx_params_t slots[RFX_PARAM_SLOTS];
    _Atomic int64_t paramEpoch;
    int64_t paramEpochSeen;
    rfx_params_t active;

    int32_t kind;
    float wet;
    float fadeStep;

    // The spring.
    rfx_spring springs[RFX_SPRINGS];
    int32_t stretch;
    float preLP, preHP, preHPIn;

    // The gated room.
    rfx_diffuser diffusers[RFX_DIFFUSERS];
    rfx_fdn_line fdn[RFX_FDN];
    float fastEnv, slowEnv, gate;
    int64_t holdLeft, refractory;

    // The tape.
    rfx_tape_channel tape[2];
    float tapeDelay;       // seconds, eased toward the asked time
    double wowPhase, flutterPhase;
};

static float rfx_clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

static int64_t rfx_read_published(struct rfx_state *st, rfx_params_t *out) {
    int64_t epoch = atomic_load_explicit(&st->paramEpoch, memory_order_acquire);
    for (int attempt = 0; attempt < RFX_ADOPT_ATTEMPTS; attempt++) {
        *out = st->slots[(size_t)(epoch % RFX_PARAM_SLOTS)];
        atomic_thread_fence(memory_order_acquire);
        const int64_t after = atomic_load_explicit(&st->paramEpoch, memory_order_relaxed);
        if (after - epoch <= RFX_PARAM_SLOTS - 2) return epoch;
        epoch = after;
    }
    return -1;
}

static void rfx_adopt(struct rfx_state *st, int fade) {
    if (atomic_load_explicit(&st->paramEpoch, memory_order_acquire) == st->paramEpochSeen) return;
    rfx_params_t published;
    const int64_t epoch = rfx_read_published(st, &published);
    if (epoch < 0) return;
    st->active = published;
    st->paramEpochSeen = epoch;
    if (!fade) {
        st->kind = published.kind;
        st->wet = published.kind == RFX_OFF ? 0.0f : 1.0f;
        st->tapeDelay = rfx_clampf(published.delaySeconds, 0.01f, (float)RFX_TAPE_SECONDS - 0.1f);
    }
}

static float *rfx_line(int32_t length) { return (float *)calloc((size_t)length, sizeof(float)); }

rfx_t *rfx_create(double sampleRate, int32_t channels) {
    if (!(sampleRate > 0.0) || channels <= 0 || channels > 2) return NULL;
    struct rfx_state *st = (struct rfx_state *)calloc(1, sizeof(struct rfx_state));
    if (!st) return NULL;
    st->sampleRate = sampleRate;
    st->channels = channels;
    st->fadeStep = (float)(1.0 / (RFX_FADE_MS * 0.001 * sampleRate));
    int32_t stretch = (int32_t)lround(sampleRate / (2.0 * RFX_SPRING_TRANSITION_HZ));
    st->stretch = stretch < 1 ? 1 : (stretch > RFX_STRETCH_MAX ? RFX_STRETCH_MAX : stretch);
    // Four springs of different lengths, so the two sides do not ring together.
    static const double springMS[RFX_SPRINGS] = { 33.1, 41.7, 36.9, 45.3 };
    int ok = 1;
    for (int s = 0; s < RFX_SPRINGS; s++) {
        rfx_spring *sp = &st->springs[s];
        sp->delay = (int32_t)lround(springMS[s] * 0.001 * sampleRate);
        sp->lineLength = sp->delay + 2;
        sp->line = rfx_line(sp->lineLength);
        ok = ok && sp->line;
    }
    static const double diffuserMS[RFX_DIFFUSERS] = { 2.96, 2.23, 7.90, 5.77 };
    for (int d = 0; d < RFX_DIFFUSERS; d++) {
        st->diffusers[d].length = (int32_t)lround(diffuserMS[d] * 0.001 * sampleRate);
        st->diffusers[d].line = rfx_line(st->diffusers[d].length);
        ok = ok && st->diffusers[d].line;
    }
    static const double fdnMS[RFX_FDN] = { 29.7, 37.1, 41.1, 43.7 };
    for (int k = 0; k < RFX_FDN; k++) {
        st->fdn[k].length = (int32_t)lround(fdnMS[k] * 0.001 * sampleRate);
        st->fdn[k].line = rfx_line(st->fdn[k].length);
        ok = ok && st->fdn[k].line;
    }
    for (int c = 0; c < 2; c++) {
        st->tape[c].length = (int32_t)lround(RFX_TAPE_SECONDS * sampleRate) + 4;
        st->tape[c].line = rfx_line(st->tape[c].length);
        ok = ok && st->tape[c].line;
    }
    if (!ok) {
        rfx_destroy(st);
        return NULL;
    }
    rfx_params_t off = { RFX_OFF, 0.5f, 4200.0f, 0.375f, 0.35f, 0.4f };
    st->slots[0] = off;
    st->active = off;
    atomic_store_explicit(&st->paramEpoch, 0, memory_order_relaxed);
    st->paramEpochSeen = 0;
    rfx_reset(st);
    return st;
}

void rfx_destroy(rfx_t *fx) {
    struct rfx_state *st = fx;
    if (!st) return;
    for (int s = 0; s < RFX_SPRINGS; s++) free(st->springs[s].line);
    for (int d = 0; d < RFX_DIFFUSERS; d++) free(st->diffusers[d].line);
    for (int k = 0; k < RFX_FDN; k++) free(st->fdn[k].line);
    for (int c = 0; c < 2; c++) free(st->tape[c].line);
    free(st);
}

static void rfx_silence(struct rfx_state *st) {
    for (int s = 0; s < RFX_SPRINGS; s++) {
        rfx_spring *sp = &st->springs[s];
        memset(sp->x, 0, sizeof(sp->x));
        memset(sp->y, 0, sizeof(sp->y));
        sp->at = 0;
        memset(sp->line, 0, (size_t)sp->lineLength * sizeof(float));
        sp->write = 0;
        sp->lp1 = sp->lp2 = sp->hp = sp->hpIn = sp->back = 0;
    }
    st->preLP = st->preHP = st->preHPIn = 0;
    for (int d = 0; d < RFX_DIFFUSERS; d++) {
        memset(st->diffusers[d].line, 0, (size_t)st->diffusers[d].length * sizeof(float));
        st->diffusers[d].write = 0;
    }
    for (int k = 0; k < RFX_FDN; k++) {
        memset(st->fdn[k].line, 0, (size_t)st->fdn[k].length * sizeof(float));
        st->fdn[k].write = 0;
        st->fdn[k].damp = 0;
    }
    st->fastEnv = st->slowEnv = st->gate = 0;
    st->holdLeft = st->refractory = 0;
    for (int c = 0; c < 2; c++) {
        memset(st->tape[c].line, 0, (size_t)st->tape[c].length * sizeof(float));
        st->tape[c].write = 0;
        st->tape[c].hp = st->tape[c].hpIn = st->tape[c].lp1 = st->tape[c].lp2 = 0;
    }
    st->wowPhase = 0;
    st->flutterPhase = 0.37;
}

void rfx_reset(rfx_t *fx) {
    struct rfx_state *st = fx;
    if (!st) return;
    rfx_silence(st);
    st->paramEpochSeen = -1;
    rfx_adopt(st, 0);
}

void rfx_set_params(rfx_t *fx, const rfx_params_t *params) {
    struct rfx_state *st = fx;
    if (!st || !params) return;
    const int64_t epoch = atomic_load_explicit(&st->paramEpoch, memory_order_relaxed) + 1;
    st->slots[(size_t)(epoch % RFX_PARAM_SLOTS)] = *params;
    atomic_store_explicit(&st->paramEpoch, epoch, memory_order_release);
}

static inline float rfx_onepole(float *state, float x, float k) {
    *state += k * (x - *state);
    return *state;
}

/// A one-pole high-pass: what the low-pass leaves out.
static inline float rfx_highpass(float *lowState, float x, float k) {
    *lowState += k * (x - *lowState);
    return x - *lowState;
}

static inline float rfx_coefficient(double fs, double hz) {
    return (float)(1.0 - exp(-2.0 * RFX_PI * hz / fs));
}

/// One spring, one sample: `in` goes in at the transducer, what reaches the pickup comes out.
static inline float rfx_spring_sample(struct rfx_state *st, rfx_spring *sp, float in, float g, float lpK, float hpK) {
    const int32_t K = st->stretch;
    // The trip, then the dispersion: each lap is a chirp.
    float u = in + g * sp->back;
    const int32_t at = sp->at;
    for (int s = 0; s < RFX_SPRING_STAGES; s++) {
        const float xK = sp->x[s][at], yK = sp->y[s][at];
        const float y = RFX_SPRING_A * u + xK - RFX_SPRING_A * yK;
        sp->x[s][at] = u;
        sp->y[s][at] = y;
        u = y;
    }
    sp->at = (at + 1) % K;
    sp->line[sp->write] = u;
    int32_t read = sp->write - sp->delay;
    if (read < 0) read += sp->lineLength;
    const float out = sp->line[read];
    sp->write = (sp->write + 1) % sp->lineLength;
    // Darker and thinner each time round.
    float back = rfx_onepole(&sp->lp1, out, lpK);
    back = rfx_onepole(&sp->lp2, back, lpK);
    back = rfx_highpass(&sp->hp, back, hpK);
    sp->back = back;
    return out;
}

void rfx_process(rfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames) {
    struct rfx_state *st = fx;
    if (!st || !channels || frames <= 0) return;
    rfx_adopt(st, 1);
    const int32_t n = channelCount < st->channels ? channelCount : st->channels;
    if (n <= 0) return;
    const int32_t wanted = st->active.kind;
    if (st->kind == RFX_OFF && st->wet <= 0.0f && wanted == RFX_OFF) return;  // off: the signal passes

    const double fs = st->sampleRate;
    const rfx_params_t *p = &st->active;
    // The spring.
    const double rt60 = 1.0 + 3.0 * rfx_clampf(p->decay, 0, 1);
    const float springLP = rfx_coefficient(fs, rfx_clampf(p->toneHz, 800, 8000));
    const float springHP = rfx_coefficient(fs, 110.0);
    const float preLP = rfx_coefficient(fs, 5000.0);
    const float preHP = rfx_coefficient(fs, 180.0);
    float springGain[RFX_SPRINGS];
    for (int s = 0; s < RFX_SPRINGS; s++) {
        // A lap is the trip plus the dispersion's mean delay, near a third of the trip again.
        const double lap = st->springs[s].delay / fs * 1.35;
        springGain[s] = (float)pow(10.0, -3.0 * lap / rt60);
    }
    // The room.
    const double roomRT = 1.3;
    float fdnGain[RFX_FDN];
    for (int k = 0; k < RFX_FDN; k++) fdnGain[k] = (float)pow(10.0, -3.0 * (st->fdn[k].length / fs) / roomRT);
    const float fdnDamp = rfx_coefficient(fs, 9000.0);
    const float fastAttack = rfx_coefficient(fs, 1.0 / (2 * RFX_PI * 0.0005));
    const float fastRelease = rfx_coefficient(fs, 1.0 / (2 * RFX_PI * 0.02));
    const float slowK = rfx_coefficient(fs, 1.0 / (2 * RFX_PI * 0.3));
    const float gateOpen = rfx_coefficient(fs, 1.0 / (2 * RFX_PI * 0.001));
    const float gateClose = rfx_coefficient(fs, 1.0 / (2 * RFX_PI * 0.025));
    const int64_t hold = (int64_t)(rfx_clampf(p->decay, 0.08f, 1.0f) * fs);
    // The tape.
    const float tapeTarget = rfx_clampf(p->delaySeconds, 0.01f, (float)RFX_TAPE_SECONDS - 0.1f);
    const float tapeGlide = (float)(1.0 - exp(-1.0 / (0.25 * fs)));
    const float tapeLP = rfx_coefficient(fs, rfx_clampf(p->toneHz, 500, 12000));
    const float tapeHP = rfx_coefficient(fs, 120.0);
    const float feedback = rfx_clampf(p->feedback, 0, 0.95f);
    const float wow = rfx_clampf(p->wow, 0, 1);

    for (int32_t i = 0; i < frames; i++) {
        if (st->kind != wanted) {
            st->wet -= st->fadeStep;
            if (st->wet <= 0.0f) {
                st->wet = 0.0f;
                st->kind = wanted;
                rfx_silence(st);
                st->tapeDelay = tapeTarget;
            }
        } else if (st->kind != RFX_OFF && st->wet < 1.0f) {
            st->wet += st->fadeStep;
            if (st->wet > 1.0f) st->wet = 1.0f;
        }
        const float wet = st->wet;
        float in[2] = { channels[0][i], n > 1 ? channels[1][i] : channels[0][i] };
        float out[2] = { 0, 0 };

        if (st->kind == RFX_OFF) {
            // Settled off (an effect fading out is still its own kind until it has): the signal
            // passes as it came, to the Apple unit after this one.
            continue;
        }
        if (st->kind == RFX_SPRING) {
            // One transducer, fed the sum, a little driven, thinned and darkened as a tank hears it.
            float m = 0.5f * (in[0] + in[1]);
            m = tanhf(1.5f * m) / 1.5f;
            m = rfx_onepole(&st->preLP, m, preLP);
            m = rfx_highpass(&st->preHP, m, preHP);
            float taps[RFX_SPRINGS];
            for (int s = 0; s < RFX_SPRINGS; s++) taps[s] = rfx_spring_sample(st, &st->springs[s], m, springGain[s], springLP, springHP);
            out[0] = 0.55f * (taps[0] + taps[1]);
            out[1] = 0.55f * (taps[2] + taps[3]);
        } else if (st->kind == RFX_GATED) {
            float m = 0.5f * (in[0] + in[1]);
            // The gate's key: a hit is the fast envelope jumping well over the slow one.
            const float rect = fabsf(m);
            st->fastEnv += (rect > st->fastEnv ? fastAttack : fastRelease) * (rect - st->fastEnv);
            st->slowEnv += slowK * (rect - st->slowEnv);
            if (st->refractory > 0) st->refractory--;
            if (st->refractory == 0 && st->fastEnv > 0.001f && st->fastEnv > 2.2f * st->slowEnv + 0.0002f) {
                st->holdLeft = hold;
                st->refractory = (int64_t)(0.03 * fs);
            }
            const float target = st->holdLeft > 0 ? 1.0f : 0.0f;
            if (st->holdLeft > 0) st->holdLeft--;
            st->gate += (target > st->gate ? gateOpen : gateClose) * (target - st->gate);
            // Diffuse, then the room: four lines through a Householder matrix.
            float u = m;
            for (int d = 0; d < RFX_DIFFUSERS; d++) {
                rfx_diffuser *df = &st->diffusers[d];
                const float delayed = df->line[df->write];
                const float v = u + 0.7f * delayed;
                df->line[df->write] = v;
                df->write = (df->write + 1) % df->length;
                u = delayed - 0.7f * v;
            }
            float taps[RFX_FDN], sum = 0;
            for (int k = 0; k < RFX_FDN; k++) {
                taps[k] = st->fdn[k].line[st->fdn[k].write];
                sum += taps[k];
            }
            for (int k = 0; k < RFX_FDN; k++) {
                rfx_fdn_line *line = &st->fdn[k];
                float fed = (taps[k] - 0.5f * sum) * fdnGain[k];
                fed = rfx_onepole(&line->damp, fed, fdnDamp);
                line->line[line->write] = fed + u;
                line->write = (line->write + 1) % line->length;
            }
            out[0] = 0.6f * (taps[0] + taps[2]) * st->gate;
            out[1] = 0.6f * (taps[1] + taps[3]) * st->gate;
        } else if (st->kind == RFX_TAPE) {
            st->tapeDelay += tapeGlide * (tapeTarget - st->tapeDelay);
            for (int32_t c = 0; c < 2; c++) {
                rfx_tape_channel *t = &st->tape[c];
                // The speed wanders: a slow wow and a quicker flutter, a little apart on each side.
                const double drift = 0.003 * sin(2 * RFX_PI * st->wowPhase + c * 0.9)
                                   + 0.0008 * sin(2 * RFX_PI * st->flutterPhase + c * 1.7);
                const double seconds = st->tapeDelay * (1.0 + wow * drift);
                const double read = (double)t->write - seconds * fs;
                double base = floor(read);
                const float frac = (float)(read - base);
                int32_t i0 = (int32_t)base % t->length;
                if (i0 < 0) i0 += t->length;
                const int32_t i1 = (i0 + 1) % t->length;
                const float y = t->line[i0] + (t->line[i1] - t->line[i0]) * frac;
                // Round again: saturated, not clipped, and through the loop's EQ.
                float back = tanhf(1.4f * feedback * y) / 1.4f;
                float w = in[c] + back;
                w = rfx_highpass(&t->hp, w, tapeHP);
                w = rfx_onepole(&t->lp1, w, tapeLP);
                w = rfx_onepole(&t->lp2, w, tapeLP);
                t->line[t->write] = w;
                t->write = (t->write + 1) % t->length;
                out[c] = y;
            }
            st->wowPhase += 0.53 / fs;
            if (st->wowPhase >= 1.0) st->wowPhase -= 1.0;
            st->flutterPhase += 6.1 / fs;
            if (st->flutterPhase >= 1.0) st->flutterPhase -= 1.0;
        }
        for (int32_t c = 0; c < n; c++) channels[c][i] = out[c] * wet;
    }
}
