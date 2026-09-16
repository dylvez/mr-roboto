// Realtime voice rendering core. See include/CVoiceRender.h for the contract.
//
// Everything the audio thread touches is allocated in vr_create and lives until vr_destroy: the
// voice pool, the event ring, and the four zone-table slots. vr_render takes no lock, allocates
// nothing, and reads no globals that anything else writes without an atomic.
//
// Layout of the voice pool: slots [0, maxVoices) hold sounding voices, slots
// [maxVoices, 2 * maxVoices) hold the declick tails of stolen voices. A tail is an ordinary voice
// in the declick stage; splitting them out is what lets a steal be click-free without letting
// tails eat the polyphony the caller asked for.

#include "CVoiceRender.h"

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) || defined(__i386__)
#include <pmmintrin.h>
#include <xmmintrin.h>
#endif

// Determinism: no fused multiply-add contraction. Left to the compiler, `a + (b - a) * frac` in
// the interpolator may or may not fuse depending on the optimisation level and the target, which
// would make "identical event sequence, identical samples" hold only within one build. Turning
// contraction off costs nothing measurable here and makes the output stable across builds.
#pragma STDC FP_CONTRACT OFF

// MARK: - Denormal flushing
//
// A release tail decaying towards zero walks straight into denormal territory, where some cores
// take a microcoded slow path that can cost hundreds of cycles per operation — the classic way an
// idle sampler blows its deadline. Flush-to-zero is set for the duration of the render callback
// and restored on the way out so the caller's FP mode is not disturbed. Flushing is deterministic
// on a given machine, so it does not compromise the sample-identical guarantee.

#if defined(__aarch64__)
#define VR_FPCR_FZ (1ull << 24)
typedef uint64_t vr_fp_mode_t;
static inline vr_fp_mode_t vr_fp_mode_begin(void) {
    uint64_t v;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(v));
    uint64_t n = v | VR_FPCR_FZ;
    if (n != v) __asm__ __volatile__("msr fpcr, %0" : : "r"(n));
    return v;
}
static inline void vr_fp_mode_end(vr_fp_mode_t v) {
    __asm__ __volatile__("msr fpcr, %0" : : "r"(v));
}
#elif defined(__x86_64__) || defined(__i386__)
typedef unsigned int vr_fp_mode_t;
static inline vr_fp_mode_t vr_fp_mode_begin(void) {
    unsigned int v = _mm_getcsr();
    _mm_setcsr(v | 0x8040u); // FTZ | DAZ
    return v;
}
static inline void vr_fp_mode_end(vr_fp_mode_t v) { _mm_setcsr(v); }
#else
typedef int vr_fp_mode_t;
static inline vr_fp_mode_t vr_fp_mode_begin(void) { return 0; }
static inline void vr_fp_mode_end(vr_fp_mode_t v) { (void)v; }
#endif

// MARK: - Internal types

enum {
    VR_STAGE_FREE = 0,
    VR_STAGE_ATTACK,
    VR_STAGE_DECAY,
    VR_STAGE_SUSTAIN,
    VR_STAGE_RELEASE,
    /// Ramping to zero over the declick window, still reading the sample.
    VR_STAGE_DECLICK,
    /// Ramping to zero over the declick window while holding its last sample value, reading
    /// nothing. Used when the zone data under a voice is gone or the sample ran out mid-note.
    VR_STAGE_ZOMBIE,
};

/// Number of zone-table slots. Three would be enough for the publish rule below; four leaves a
/// slot of margin.
#define VR_ZONE_SLOTS 4
#define VR_QUEUE_MASK (VR_EVENT_QUEUE_CAPACITY - 1)
#if (VR_EVENT_QUEUE_CAPACITY & VR_QUEUE_MASK) != 0
#error "VR_EVENT_QUEUE_CAPACITY must be a power of two"
#endif

typedef struct {
    int32_t stage;
    int64_t voiceId;
    /// Note-on order. Lower is older; the tiebreaker that keeps voice stealing deterministic.
    int64_t serial;
    int32_t zoneIndex;

    // Zone parameters captured at note-on. A voice never re-reads the zone table, so publishing a
    // new table never changes a note already in flight.
    const float *const *channels;
    int32_t frameCount;
    int32_t channelCount;
    int32_t startFrame;
    int32_t endFrame; // exclusive
    int32_t loopStart;
    int32_t loopEnd;
    int32_t loopEnabled;
    int32_t group;
    int32_t offBy;
    int32_t offMode;

    double pos;      // fractional read position, in source frames
    double inc;      // base increment: pitchRatio * sourceRate / engineRate
    double rateMul;  // per-voice pitch multiplier from VR_PARAM_VOICE_PITCH_RATIO

    float zoneGain;  // zone gain * velocity
    float voiceGain; // VR_PARAM_VOICE_GAIN
    float panL;
    float panR;

    float env;
    float attackInc;
    float decayInc;
    float sustainLevel;
    float releaseInc; // computed when release starts, so release always lasts `release` seconds
    float releaseSeconds;
    float declickInc;

    float lastL; // last source values, held through the zombie ramp
    float lastR;
} vr_voice_t;

typedef struct {
    const vr_zone_t *zones;
    int32_t count;
    int64_t epoch;
} vr_zone_slot_t;

struct vr_engine {
    double sampleRate;
    int32_t maxVoices;
    int32_t voiceCapacity; // 2 * maxVoices: sounding slots plus declick tails
    int32_t maxChannels;
    int32_t declickFrames;

    vr_voice_t *voices;

    // Zone table double buffer (four slots, see vr_set_zones).
    vr_zone_slot_t slots[VR_ZONE_SLOTS];
    _Atomic int32_t publishedSlot;
    _Atomic int32_t slotInUse;
    _Atomic int64_t zoneEpoch;
    _Atomic int64_t zoneEpochInUse;
    int64_t lastEpochSeen; // audio thread only

    // Single-producer single-consumer event ring. head is the consumer's, tail the producer's.
    vr_event_t queue[VR_EVENT_QUEUE_CAPACITY];
    _Atomic uint32_t qHead;
    _Atomic uint32_t qTail;

    _Atomic int64_t droppedEvents;
    _Atomic int64_t stolenVoices;
    _Atomic int64_t hardCuts;
    _Atomic int32_t activeVoices;

    int64_t serialCounter; // audio thread only
    float masterGain;      // audio thread only
};

// MARK: - Small helpers

static inline float vr_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline bool vr_finite(float v) { return v == v && v > -INFINITY && v < INFINITY; }

static inline void vr_equal_power_pan(float pan, float *outL, float *outR) {
    // -1..1 mapped onto a quarter circle: centre is -3 dB on each side, the sum of squares is 1.
    float p = vr_clampf(pan, -1.0f, 1.0f);
    float angle = (p + 1.0f) * 0.25f * 3.14159265358979323846f;
    *outL = cosf(angle);
    *outR = sinf(angle);
}

static inline void vr_free_voice(vr_voice_t *v) {
    v->stage = VR_STAGE_FREE;
    v->env = 0.0f;
    v->channels = NULL;
    v->voiceId = 0;
}

/// Puts a voice into the declick ramp from wherever its envelope is now.
static inline void vr_start_declick(const vr_engine_t *e, vr_voice_t *v) {
    if (v->stage == VR_STAGE_FREE) return;
    v->stage = VR_STAGE_DECLICK;
    v->declickInc = e->declickFrames > 0 ? v->env / (float)e->declickFrames : v->env;
    if (v->declickInc <= 0.0f) vr_free_voice(v);
}

/// Puts a voice into the zombie ramp: it holds its last sample value and reads nothing more.
static inline void vr_start_zombie(const vr_engine_t *e, vr_voice_t *v) {
    if (v->stage == VR_STAGE_FREE) return;
    v->stage = VR_STAGE_ZOMBIE;
    v->channels = NULL;
    v->declickInc = e->declickFrames > 0 ? v->env / (float)e->declickFrames : v->env;
    if (v->declickInc <= 0.0f) vr_free_voice(v);
}

static inline void vr_start_release(const vr_engine_t *e, vr_voice_t *v) {
    if (v->stage == VR_STAGE_FREE || v->stage == VR_STAGE_RELEASE ||
        v->stage == VR_STAGE_DECLICK || v->stage == VR_STAGE_ZOMBIE) {
        return;
    }
    int32_t frames = (int32_t)(v->releaseSeconds * e->sampleRate + 0.5);
    if (frames <= 0) {
        vr_start_declick(e, v);
        return;
    }
    v->stage = VR_STAGE_RELEASE;
    v->releaseInc = v->env / (float)frames;
    if (v->releaseInc <= 0.0f) vr_free_voice(v);
}

// MARK: - Create / destroy

vr_engine_t *vr_create(int32_t maxVoices, double sampleRate, int32_t maxChannels) {
    if (maxVoices <= 0 || maxChannels <= 0) return NULL;
    if (!(sampleRate > 0.0) || sampleRate > 1.0e7) return NULL;
    if (maxVoices > 4096 || maxChannels > 64) return NULL;

    vr_engine_t *e = (vr_engine_t *)calloc(1, sizeof(vr_engine_t));
    if (!e) return NULL;

    e->sampleRate = sampleRate;
    e->maxVoices = maxVoices;
    e->voiceCapacity = maxVoices * 2;
    e->maxChannels = maxChannels;
    e->declickFrames = (int32_t)(VR_DECLICK_MS * 0.001 * sampleRate + 0.5);
    if (e->declickFrames < 1) e->declickFrames = 1;
    e->masterGain = 1.0f;

    e->voices = (vr_voice_t *)calloc((size_t)e->voiceCapacity, sizeof(vr_voice_t));
    if (!e->voices) {
        free(e);
        return NULL;
    }

    atomic_store_explicit(&e->publishedSlot, 0, memory_order_relaxed);
    atomic_store_explicit(&e->slotInUse, -1, memory_order_relaxed);
    atomic_store_explicit(&e->zoneEpoch, 0, memory_order_relaxed);
    atomic_store_explicit(&e->zoneEpochInUse, 0, memory_order_relaxed);
    atomic_store_explicit(&e->qHead, 0, memory_order_relaxed);
    atomic_store_explicit(&e->qTail, 0, memory_order_relaxed);
    atomic_store_explicit(&e->droppedEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&e->stolenVoices, 0, memory_order_relaxed);
    atomic_store_explicit(&e->hardCuts, 0, memory_order_relaxed);
    atomic_store_explicit(&e->activeVoices, 0, memory_order_relaxed);
    return e;
}

void vr_destroy(vr_engine_t *engine) {
    if (!engine) return;
    free(engine->voices);
    free(engine);
}

// MARK: - Zone table

void vr_set_zones(vr_engine_t *engine, const vr_zone_t *zones, int32_t count) {
    if (!engine) return;
    if (!zones || count < 0) count = 0;

    // Pick a slot that is neither the one currently published (the audio thread may be about to
    // read it) nor the one it told us it is rendering from. The audio thread stamps `slotInUse`
    // at the top of the block and leaves it there for the whole block, so with a single owner
    // thread those two exclusions are enough: whatever we write, nobody is reading.
    int32_t published = atomic_load_explicit(&engine->publishedSlot, memory_order_relaxed);
    int32_t inUse = atomic_load_explicit(&engine->slotInUse, memory_order_relaxed);
    int32_t slot = -1;
    for (int32_t i = 1; i <= VR_ZONE_SLOTS; i++) {
        int32_t candidate = (published + i) % VR_ZONE_SLOTS;
        if (candidate != published && candidate != inUse) {
            slot = candidate;
            break;
        }
    }
    if (slot < 0) return; // unreachable with VR_ZONE_SLOTS >= 3

    int64_t epoch = atomic_load_explicit(&engine->zoneEpoch, memory_order_relaxed) + 1;
    engine->slots[slot].zones = zones;
    engine->slots[slot].count = count;
    engine->slots[slot].epoch = epoch;

    // Release: the slot's fields above must be visible before the index that points at them.
    atomic_store_explicit(&engine->zoneEpoch, epoch, memory_order_relaxed);
    atomic_store_explicit(&engine->publishedSlot, slot, memory_order_release);
}

int64_t vr_zones_epoch(const vr_engine_t *engine) {
    if (!engine) return 0;
    return atomic_load_explicit(&engine->zoneEpoch, memory_order_relaxed);
}

int64_t vr_zones_epoch_in_use(const vr_engine_t *engine) {
    if (!engine) return 0;
    return atomic_load_explicit(&engine->zoneEpochInUse, memory_order_relaxed);
}

// MARK: - Event queue (single producer, single consumer)

int vr_push_event(vr_engine_t *engine, const vr_event_t *ev) {
    if (!engine || !ev) return -1;
    uint32_t tail = atomic_load_explicit(&engine->qTail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&engine->qHead, memory_order_acquire);
    if ((uint32_t)(tail - head) >= (uint32_t)VR_EVENT_QUEUE_CAPACITY) {
        atomic_fetch_add_explicit(&engine->droppedEvents, 1, memory_order_relaxed);
        return 1;
    }
    engine->queue[tail & VR_QUEUE_MASK] = *ev;
    // Release: the slot's contents must be visible before the consumer can see the new tail.
    atomic_store_explicit(&engine->qTail, tail + 1, memory_order_release);
    return 0;
}

/// Consumer side. Returns the head event if there is one and it falls inside this block, with its
/// offset clamped into [0, frameCount). An event from the past lands on frame 0 rather than
/// being dropped.
static inline const vr_event_t *vr_peek_due(vr_engine_t *e, int64_t startFrame, int32_t frameCount,
                                            int32_t *outOffset) {
    uint32_t head = atomic_load_explicit(&e->qHead, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&e->qTail, memory_order_acquire);
    if (head == tail) return NULL;
    const vr_event_t *ev = &e->queue[head & VR_QUEUE_MASK];
    int64_t delta = ev->frameTime - startFrame;
    if (delta >= (int64_t)frameCount) return NULL; // due in a later block
    *outOffset = delta < 0 ? 0 : (int32_t)delta;
    return ev;
}

static inline void vr_pop_event(vr_engine_t *e) {
    uint32_t head = atomic_load_explicit(&e->qHead, memory_order_relaxed);
    atomic_store_explicit(&e->qHead, head + 1, memory_order_release);
}

// MARK: - Voice allocation

static vr_voice_t *vr_find_free_tail(vr_engine_t *e) {
    for (int32_t i = e->maxVoices; i < e->voiceCapacity; i++) {
        if (e->voices[i].stage == VR_STAGE_FREE) return &e->voices[i];
    }
    // Every tail busy: take the quietest one, which is the least audible hard cut available.
    vr_voice_t *quietest = NULL;
    for (int32_t i = e->maxVoices; i < e->voiceCapacity; i++) {
        vr_voice_t *v = &e->voices[i];
        if (!quietest || v->env < quietest->env ||
            (v->env == quietest->env && v->serial < quietest->serial)) {
            quietest = v;
        }
    }
    atomic_fetch_add_explicit(&e->hardCuts, 1, memory_order_relaxed);
    return quietest;
}

/// Finds a slot for a new note, stealing if the pool is full.
///
/// Stealing policy: the quietest voice already in its release or declick stage goes first — it was
/// on its way out anyway — and only if none is releasing does the oldest sounding voice go, by
/// note-on serial. Ties break on the lower serial so the choice is deterministic. The victim is
/// moved into a tail slot and ramped to zero over the declick window rather than cut, so a steal
/// never clicks.
static vr_voice_t *vr_allocate_voice(vr_engine_t *e) {
    for (int32_t i = 0; i < e->maxVoices; i++) {
        if (e->voices[i].stage == VR_STAGE_FREE) return &e->voices[i];
    }

    vr_voice_t *victim = NULL;
    bool victimReleasing = false;
    for (int32_t i = 0; i < e->maxVoices; i++) {
        vr_voice_t *v = &e->voices[i];
        bool releasing = (v->stage == VR_STAGE_RELEASE || v->stage == VR_STAGE_DECLICK ||
                          v->stage == VR_STAGE_ZOMBIE);
        if (!victim) {
            victim = v;
            victimReleasing = releasing;
            continue;
        }
        if (releasing && !victimReleasing) {
            victim = v;
            victimReleasing = true;
        } else if (releasing == victimReleasing) {
            if (releasing) {
                if (v->env < victim->env || (v->env == victim->env && v->serial < victim->serial)) {
                    victim = v;
                }
            } else if (v->serial < victim->serial) {
                victim = v;
            }
        }
    }
    if (!victim) return &e->voices[0];

    vr_voice_t *tail = vr_find_free_tail(e);
    if (tail) {
        *tail = *victim;
        vr_start_declick(e, tail);
    }
    atomic_fetch_add_explicit(&e->stolenVoices, 1, memory_order_relaxed);
    vr_free_voice(victim);
    return victim;
}

static void vr_start_voice(vr_engine_t *e, const vr_zone_t *z, int32_t zoneIndex,
                           int64_t voiceId, float velocity) {
    if (!z->channels || z->frameCount <= 0 || z->channelCount <= 0) return;
    if (!(z->sourceSampleRate > 0.0)) return;
    if (!vr_finite(z->pitchRatio) || z->pitchRatio <= 0.0f) return;
    if (!vr_finite(z->gain)) return;
    for (int32_t c = 0; c < z->channelCount; c++) {
        if (!z->channels[c]) return;
    }

    int32_t start = z->sampleStart < 0 ? 0 : z->sampleStart;
    if (start >= z->frameCount) return;
    int32_t end = (z->sampleEnd <= 0 || z->sampleEnd > z->frameCount) ? z->frameCount : z->sampleEnd;
    if (end <= start) return;

    vr_voice_t *v = vr_allocate_voice(e);
    if (!v) return;

    memset(v, 0, sizeof(*v));
    v->voiceId = voiceId;
    v->serial = ++e->serialCounter;
    v->zoneIndex = zoneIndex;
    v->channels = z->channels;
    v->frameCount = z->frameCount;
    v->channelCount = z->channelCount;
    v->startFrame = start;
    v->endFrame = end;

    int32_t ls = z->loopStart < start ? start : z->loopStart;
    int32_t le = (z->loopEnd <= 0 || z->loopEnd > end) ? end : z->loopEnd;
    v->loopEnabled = (z->loopEnabled != 0 && le - ls >= 2) ? 1 : 0;
    v->loopStart = ls;
    v->loopEnd = le;

    v->group = z->group;
    v->offBy = z->offBy;
    v->offMode = z->offMode;

    v->pos = (double)start;
    v->inc = (double)z->pitchRatio * z->sourceSampleRate / e->sampleRate;
    if (!(v->inc > 0.0) || v->inc != v->inc) v->inc = 1.0;
    v->rateMul = 1.0;

    float vel = vr_finite(velocity) ? vr_clampf(velocity, 0.0f, 1.0f) : 1.0f;
    v->zoneGain = z->gain * vel;
    v->voiceGain = 1.0f;
    vr_equal_power_pan(vr_finite(z->pan) ? z->pan : 0.0f, &v->panL, &v->panR);

    float sustain = vr_finite(z->sustain) ? vr_clampf(z->sustain, 0.0f, 1.0f) : 1.0f;
    int32_t attackFrames = vr_finite(z->attack) ? (int32_t)(z->attack * e->sampleRate + 0.5) : 0;
    int32_t decayFrames = vr_finite(z->decay) ? (int32_t)(z->decay * e->sampleRate + 0.5) : 0;
    v->sustainLevel = sustain;
    v->releaseSeconds = (vr_finite(z->release) && z->release > 0.0f) ? z->release : 0.0f;
    v->attackInc = attackFrames > 0 ? 1.0f / (float)attackFrames : 0.0f;
    v->decayInc = decayFrames > 0 ? (1.0f - sustain) / (float)decayFrames : 0.0f;

    if (attackFrames > 0) {
        v->env = 0.0f;
        v->stage = VR_STAGE_ATTACK;
    } else if (v->decayInc > 0.0f) {
        v->env = 1.0f;
        v->stage = VR_STAGE_DECAY;
    } else {
        v->env = sustain >= 1.0f ? 1.0f : sustain;
        v->stage = VR_STAGE_SUSTAIN;
        if (v->env <= 0.0f) vr_free_voice(v);
    }
}

// MARK: - Events

static void vr_apply_choke(vr_engine_t *e, int32_t group) {
    if (group == 0) return;
    for (int32_t i = 0; i < e->voiceCapacity; i++) {
        vr_voice_t *v = &e->voices[i];
        if (v->stage == VR_STAGE_FREE || v->offBy != group) continue;
        if (v->stage == VR_STAGE_DECLICK || v->stage == VR_STAGE_ZOMBIE) continue;
        if (v->offMode == VR_OFF_MODE_NORMAL) {
            vr_start_release(e, v);
        } else {
            vr_start_declick(e, v);
        }
    }
}

static void vr_apply_event(vr_engine_t *e, const vr_event_t *ev, const vr_zone_t *zones,
                           int32_t zoneCount) {
    switch (ev->type) {
    case VR_EVENT_NOTE_ON: {
        if (!zones || ev->zoneIndex < 0 || ev->zoneIndex >= zoneCount) return;
        const vr_zone_t *z = &zones[ev->zoneIndex];
        // The choke fires before the new voice is allocated, so a zone that chokes its own group
        // cuts the previous hit rather than itself, and the ramp starts on this exact frame.
        vr_apply_choke(e, z->group);
        vr_start_voice(e, z, ev->zoneIndex, ev->voiceId, ev->velocity);
        break;
    }
    case VR_EVENT_NOTE_OFF: {
        for (int32_t i = 0; i < e->voiceCapacity; i++) {
            vr_voice_t *v = &e->voices[i];
            if (v->stage == VR_STAGE_FREE) continue;
            bool match;
            if (ev->voiceId != 0) {
                match = (v->voiceId == ev->voiceId);
            } else if (ev->zoneIndex >= 0) {
                match = (v->zoneIndex == ev->zoneIndex);
            } else {
                match = true;
            }
            if (match) vr_start_release(e, v);
        }
        break;
    }
    case VR_EVENT_ALL_NOTES_OFF: {
        for (int32_t i = 0; i < e->voiceCapacity; i++) vr_start_release(e, &e->voices[i]);
        break;
    }
    case VR_EVENT_PARAMETER_CHANGE: {
        if (!vr_finite(ev->value)) return;
        if (ev->paramId == VR_PARAM_MASTER_GAIN) {
            e->masterGain = ev->value;
            return;
        }
        for (int32_t i = 0; i < e->voiceCapacity; i++) {
            vr_voice_t *v = &e->voices[i];
            if (v->stage == VR_STAGE_FREE || v->voiceId != ev->voiceId) continue;
            switch (ev->paramId) {
            case VR_PARAM_VOICE_GAIN:
                v->voiceGain = ev->value;
                break;
            case VR_PARAM_VOICE_PAN:
                vr_equal_power_pan(ev->value, &v->panL, &v->panR);
                break;
            case VR_PARAM_VOICE_PITCH_RATIO:
                if (ev->value > 0.0f) v->rateMul = (double)ev->value;
                break;
            default:
                break;
            }
        }
        break;
    }
    default:
        break;
    }
}

/// Called once when a newly published zone table is picked up. A voice whose zone index no longer
/// exists, or whose zone now points at different sample memory, is handed to the zombie ramp: it
/// fades out from its last output without touching the old buffers again, so the caller can free
/// them as soon as the epoch is acknowledged.
static void vr_revalidate_voices(vr_engine_t *e, const vr_zone_t *zones, int32_t zoneCount) {
    for (int32_t i = 0; i < e->voiceCapacity; i++) {
        vr_voice_t *v = &e->voices[i];
        if (v->stage == VR_STAGE_FREE || v->stage == VR_STAGE_ZOMBIE) continue;
        bool ok = zones && v->zoneIndex >= 0 && v->zoneIndex < zoneCount &&
                  zones[v->zoneIndex].channels == v->channels;
        if (!ok) vr_start_zombie(e, v);
    }
}

// MARK: - Rendering

/// Advances one envelope step and returns the level for this frame. Returns a negative value once
/// the voice is finished.
static inline float vr_env_step(vr_voice_t *v) {
    switch (v->stage) {
    case VR_STAGE_ATTACK: {
        float env = v->env;
        v->env += v->attackInc;
        if (v->env >= 1.0f) {
            v->env = 1.0f;
            v->stage = v->decayInc > 0.0f ? VR_STAGE_DECAY : VR_STAGE_SUSTAIN;
        }
        return env;
    }
    case VR_STAGE_DECAY: {
        float env = v->env;
        v->env -= v->decayInc;
        if (v->env <= v->sustainLevel) {
            v->env = v->sustainLevel;
            v->stage = VR_STAGE_SUSTAIN;
        }
        return env;
    }
    case VR_STAGE_SUSTAIN:
        return v->env;
    case VR_STAGE_RELEASE: {
        float env = v->env;
        v->env -= v->releaseInc;
        if (v->env <= 0.0f) {
            v->env = 0.0f;
            v->stage = VR_STAGE_FREE;
        }
        return env;
    }
    case VR_STAGE_DECLICK:
    case VR_STAGE_ZOMBIE: {
        float env = v->env;
        v->env -= v->declickInc;
        if (v->env <= 0.0f) {
            v->env = 0.0f;
            v->stage = VR_STAGE_FREE;
        }
        return env;
    }
    default:
        return -1.0f;
    }
}

static void vr_render_voice(vr_engine_t *e, vr_voice_t *v, float *const *out, int32_t channelCount,
                            int32_t offset, int32_t frames) {
    if (v->stage == VR_STAGE_FREE || frames <= 0) return;

    const float gain = v->zoneGain * v->voiceGain * e->masterGain;
    const float gl = gain * v->panL;
    const float gr = gain * v->panR;
    float *outL = out[0];
    float *outR = channelCount >= 2 ? out[1] : NULL;

    if (v->stage == VR_STAGE_ZOMBIE) {
        // Holds the last source value and rides the ramp down; reads no sample memory.
        for (int32_t i = 0; i < frames; i++) {
            float env = vr_env_step(v);
            if (env < 0.0f) return;
            float l = v->lastL * gl * env;
            float r = v->lastR * gr * env;
            if (outR) {
                outL[offset + i] += l;
                outR[offset + i] += r;
            } else {
                outL[offset + i] += (l + r) * 0.5f;
            }
            if (v->stage == VR_STAGE_FREE) return;
        }
        return;
    }

    const float *src0 = v->channels[0];
    const float *src1 = v->channelCount > 1 ? v->channels[1] : src0;
    const int32_t last = v->frameCount - 1;
    const int32_t endFrame = v->endFrame;
    const int32_t loopStart = v->loopStart;
    const int32_t loopEnd = v->loopEnd;
    const int loopEnabled = v->loopEnabled;
    const double loopLen = (double)(loopEnd - loopStart);
    double pos = v->pos;
    const double inc = v->inc * v->rateMul;

    for (int32_t i = 0; i < frames; i++) {
        float env = vr_env_step(v);
        if (env < 0.0f) break;

        int32_t i0 = (int32_t)pos;
        if (i0 < 0) i0 = 0;
        if (i0 > last) i0 = last;
        double frac = pos - (double)i0;
        int32_t i1 = i0 + 1;
        if (loopEnabled) {
            if (i1 >= loopEnd) i1 = loopStart;
        } else if (i1 >= endFrame) {
            i1 = endFrame - 1;
        }
        if (i1 < 0) i1 = 0;
        if (i1 > last) i1 = last;

        float f = (float)frac;
        float a0 = src0[i0];
        float l = a0 + (src0[i1] - a0) * f;
        float r;
        if (src1 != src0) {
            float b0 = src1[i0];
            r = b0 + (src1[i1] - b0) * f;
        } else {
            r = l;
        }
        v->lastL = l;
        v->lastR = r;

        float ol = l * gl * env;
        float orr = r * gr * env;
        if (outR) {
            outL[offset + i] += ol;
            outR[offset + i] += orr;
        } else {
            outL[offset + i] += (ol + orr) * 0.5f;
        }

        if (v->stage == VR_STAGE_FREE) {
            v->pos = pos;
            return;
        }

        pos += inc;
        if (loopEnabled) {
            if (pos >= (double)loopEnd) {
                pos -= loopLen;
                if (pos >= (double)loopEnd || pos < (double)loopStart) pos = (double)loopStart;
            }
        } else if (pos >= (double)endFrame) {
            // Ran off the end. If the sample did not end near zero, ramp the last value out
            // rather than dropping it on the floor.
            v->pos = pos;
            if (v->env > 0.0005f && (fabsf(v->lastL * gl) > 0.0005f || fabsf(v->lastR * gr) > 0.0005f)) {
                vr_start_zombie(e, v);
            } else {
                vr_free_voice(v);
            }
            return;
        }
    }
    v->pos = pos;
}

void vr_render(vr_engine_t *engine, float *const *outChannels, int32_t channelCount,
               int32_t frameCount, int64_t startFrame) {
    if (!engine || !outChannels || frameCount <= 0 || channelCount <= 0) return;
    if (channelCount > engine->maxChannels) channelCount = engine->maxChannels;

    vr_fp_mode_t fp = vr_fp_mode_begin();

    for (int32_t c = 0; c < channelCount; c++) {
        if (outChannels[c]) memset(outChannels[c], 0, (size_t)frameCount * sizeof(float));
    }
    if (!outChannels[0]) {
        vr_fp_mode_end(fp);
        return;
    }

    // One acquire load per block: the table cannot change under us mid-block.
    int32_t slot = atomic_load_explicit(&engine->publishedSlot, memory_order_acquire);
    if (slot < 0 || slot >= VR_ZONE_SLOTS) slot = 0;
    atomic_store_explicit(&engine->slotInUse, slot, memory_order_relaxed);
    const vr_zone_t *zones = engine->slots[slot].zones;
    int32_t zoneCount = engine->slots[slot].count;
    int64_t epoch = engine->slots[slot].epoch;
    atomic_store_explicit(&engine->zoneEpochInUse, epoch, memory_order_relaxed);
    if (epoch != engine->lastEpochSeen) {
        engine->lastEpochSeen = epoch;
        vr_revalidate_voices(engine, zones, zoneCount);
    }

    int32_t seg = 0;
    while (seg < frameCount) {
        // Apply everything due at or before this frame, then render up to the next event.
        int32_t offset = 0;
        const vr_event_t *ev;
        while ((ev = vr_peek_due(engine, startFrame, frameCount, &offset)) != NULL && offset <= seg) {
            vr_apply_event(engine, ev, zones, zoneCount);
            vr_pop_event(engine);
        }
        int32_t segEnd = frameCount;
        if (ev != NULL && offset > seg && offset < frameCount) segEnd = offset;

        int32_t frames = segEnd - seg;
        for (int32_t i = 0; i < engine->voiceCapacity; i++) {
            vr_voice_t *v = &engine->voices[i];
            if (v->stage != VR_STAGE_FREE) {
                vr_render_voice(engine, v, outChannels, channelCount, seg, frames);
            }
        }
        seg = segEnd;
    }

    int32_t active = 0;
    for (int32_t i = 0; i < engine->voiceCapacity; i++) {
        if (engine->voices[i].stage != VR_STAGE_FREE) active++;
    }
    atomic_store_explicit(&engine->activeVoices, active, memory_order_relaxed);

    vr_fp_mode_end(fp);
}

// MARK: - Control and queries

void vr_reset(vr_engine_t *engine) {
    if (!engine) return;
    memset(engine->voices, 0, (size_t)engine->voiceCapacity * sizeof(vr_voice_t));
    engine->serialCounter = 0;
    engine->masterGain = 1.0f;
    uint32_t tail = atomic_load_explicit(&engine->qTail, memory_order_acquire);
    atomic_store_explicit(&engine->qHead, tail, memory_order_release);
    atomic_store_explicit(&engine->droppedEvents, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->stolenVoices, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->hardCuts, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->activeVoices, 0, memory_order_relaxed);
}

int32_t vr_active_voices(const vr_engine_t *engine) {
    if (!engine) return 0;
    return atomic_load_explicit(&engine->activeVoices, memory_order_relaxed);
}

int64_t vr_dropped_events(const vr_engine_t *engine) {
    if (!engine) return 0;
    return atomic_load_explicit(&engine->droppedEvents, memory_order_relaxed);
}

int64_t vr_stolen_voices(const vr_engine_t *engine) {
    if (!engine) return 0;
    return atomic_load_explicit(&engine->stolenVoices, memory_order_relaxed);
}

int64_t vr_hard_cuts(const vr_engine_t *engine) {
    if (!engine) return 0;
    return atomic_load_explicit(&engine->hardCuts, memory_order_relaxed);
}

int32_t vr_declick_frames(const vr_engine_t *engine) {
    if (!engine) return 0;
    return engine->declickFrames;
}
