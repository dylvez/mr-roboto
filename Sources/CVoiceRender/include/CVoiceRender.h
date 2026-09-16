// Realtime voice rendering core for the sampler (M1 task A2).
//
// macOS 27 marks `AVAudioSourceNodeRenderBlockRealtimeSafe` and its initialiser
// `__SWIFT_UNAVAILABLE_MSG("Swift is not supported for use with audio realtime threads")`, so the
// voice mixing lives here in C11 and Swift owns every allocation and every lifetime. One engine
// handle serves one source node.
//
// Thread model (three roles, and only these):
//   * owner thread   — vr_create / vr_destroy / vr_reset / vr_set_zones. Exactly one thread at a
//                      time; vr_reset and vr_set_zones are safe to call while the audio thread is
//                      rendering (see the note on vr_set_zones below).
//   * producer thread — vr_push_event. Exactly one thread (single producer). It may be the owner
//                      thread but must not be more than one thread.
//   * audio thread   — vr_render, and nothing else.
// The query functions (vr_active_voices, vr_dropped_events, ...) are relaxed atomic loads and may
// be called from anywhere at any time; they are a snapshot, not a synchronisation point.
//
// vr_render allocates nothing, takes no lock, touches no file, and calls no Objective-C or Swift.
// It is deterministic: no randomness anywhere, no time-of-day, no uninitialised reads. Two renders
// of the same event sequence from the same starting state are sample-identical.
//
// Audio is planar float throughout: `channels[c]` points at a buffer of samples for channel `c`.
#ifndef CVOICERENDER_H
#define CVOICERENDER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Capacity of the event ring, in events. Fixed at compile time so the queue can be inlined into
/// the engine and never reallocated. A 512-frame block at 48 kHz is ~10.7 ms, so this is roughly
/// 1000 events of headroom per block at any realistic note rate.
#define VR_EVENT_QUEUE_CAPACITY 1024

/// Declick ramp length in milliseconds. Applied to a choke with `VR_OFF_MODE_FAST`, to a stolen
/// voice, to a voice that runs off the end of its sample while still loud, and to a voice whose
/// zone data is pulled out from under it.
#define VR_DECLICK_MS 2.0

typedef struct vr_engine vr_engine_t;

/// How a choked voice is silenced.
typedef enum vr_off_mode {
    /// A short ramp to zero, `VR_DECLICK_MS` long: hi-hat pedal closing an open hat.
    VR_OFF_MODE_FAST = 0,
    /// The zone's own release stage.
    VR_OFF_MODE_NORMAL = 1,
} vr_off_mode;

typedef enum vr_event_type {
    /// Starts a voice on `zoneIndex` at `velocity`, tagged with the caller-assigned `voiceId`.
    VR_EVENT_NOTE_ON = 0,
    /// Releases the voice with `voiceId`; `voiceId == 0` releases every voice on `zoneIndex`, and
    /// `zoneIndex < 0` with `voiceId == 0` releases everything.
    VR_EVENT_NOTE_OFF = 1,
    /// Releases every sounding voice (the zone release stage, not a hard cut).
    VR_EVENT_ALL_NOTES_OFF = 2,
    /// Sets `paramId` to `value`, targeted by `voiceId` where the parameter is per-voice.
    VR_EVENT_PARAMETER_CHANGE = 3,
} vr_event_type;

typedef enum vr_param {
    /// Engine-wide linear gain applied to the sum of all voices. Default 1.0.
    VR_PARAM_MASTER_GAIN = 0,
    /// Linear gain of the voice with `voiceId`, multiplied into the zone gain and velocity.
    VR_PARAM_VOICE_GAIN = 1,
    /// Pan of the voice with `voiceId`, -1 hard left to +1 hard right (equal power).
    VR_PARAM_VOICE_PAN = 2,
    /// Playback rate multiplier of the voice with `voiceId`, on top of the zone's `pitchRatio`.
    VR_PARAM_VOICE_PITCH_RATIO = 3,
} vr_param;

/// One playable region of one sample. Swift builds and owns the whole table, including the sample
/// buffers `channels` points at; the render core only ever reads it.
typedef struct vr_zone {
    /// `channelCount` pointers to deinterleaved sample buffers of `frameCount` frames each.
    const float *const *channels;
    int32_t frameCount;
    int32_t channelCount;
    /// Sample rate the buffers were recorded at. Combined with the engine rate to get the
    /// resampling increment, so a 44.1 kHz sample plays at pitch on a 48 kHz engine.
    double sourceSampleRate;
    /// Playback window in source frames: `sampleStart` inclusive, `sampleEnd` exclusive.
    /// `sampleEnd <= 0` means "to `frameCount`".
    int32_t sampleStart;
    int32_t sampleEnd;
    /// Linear gain (not dB). Multiplied by velocity and by any per-voice gain.
    float gain;
    /// -1 hard left, 0 centre, +1 hard right. Equal power (-3 dB centre).
    float pan;
    /// Playback rate multiplier for pitch, precomputed by Swift from the zone's tuning in cents
    /// and the distance from the root note. 1.0 = play at the recorded pitch.
    float pitchRatio;
    /// Loop window in source frames, used when `loopEnabled` is non-zero and the window is at
    /// least two frames wide.
    int32_t loopStart;
    int32_t loopEnd;
    int32_t loopEnabled;
    /// Amplitude envelope. Attack, decay and release are seconds; sustain is a level in 0..1.
    /// Each stage is linear in amplitude, so release reaches exactly zero after `release` seconds.
    float attack;
    float decay;
    float sustain;
    float release;
    /// Choke group this zone's note-ons fire, or 0 for none.
    int32_t group;
    /// Choke group that silences this zone's sounding voices, or 0 for never.
    int32_t offBy;
    /// `vr_off_mode` used when this zone is choked.
    int32_t offMode;
} vr_zone_t;

typedef struct vr_event {
    /// Absolute render frame the event takes effect on, on the same timeline as `vr_render`'s
    /// `startFrame`. An event that lands before the current block is applied at the first frame of
    /// the block rather than dropped, so a late event is early, never lost.
    int64_t frameTime;
    /// Caller-assigned voice identity. On note-on it tags the voice (use a non-zero, monotonically
    /// increasing value); on note-off and per-voice parameter changes it selects the target.
    int64_t voiceId;
    /// A `vr_event_type`.
    int32_t type;
    /// Index into the zone table, or < 0 where the event is not zone-specific.
    int32_t zoneIndex;
    /// 0..1, already curve-mapped by Swift. Multiplied into the zone gain.
    float velocity;
    /// A `vr_param`, for `VR_EVENT_PARAMETER_CHANGE`.
    int32_t paramId;
    /// The parameter's new value.
    float value;
    /// Padding so the struct has the same layout everywhere and no bytes are left uninitialised.
    int32_t reserved;
} vr_event_t;

/// Creates an engine sized for `maxVoices` simultaneously sounding voices at `sampleRate`, mixing
/// into at most `maxChannels` output channels. Every buffer the render core will ever need is
/// allocated here. The pool also carries `maxVoices` extra internal slots for the declick tails of
/// stolen voices, so stealing never clicks and never allocates. Returns NULL on invalid arguments
/// or if allocation fails.
vr_engine_t *vr_create(int32_t maxVoices, double sampleRate, int32_t maxChannels);
void vr_destroy(vr_engine_t *engine);

/// Publishes a zone table. The engine keeps two table slots, each a (pointer, count) pair, and an
/// atomic slot index.
///
/// Guarantee: this is safe to call while the audio thread is rendering, from one owner thread at a
/// time. The new table is written into the slot the render thread is not using and published with
/// a release store of the index; `vr_render` takes one acquire load at the top of the block and
/// uses that snapshot for the whole block. So the render thread never sees a torn pointer/count
/// pair and never mixes two tables inside one block. What this does *not* do is free anything: the
/// zones and their sample buffers stay owned by Swift. Reclaiming the previous table safely means
/// waiting until the render thread has moved on, which `vr_zones_epoch` and `vr_zones_epoch_in_use`
/// let you observe: publish, then release the old table once `vr_zones_epoch_in_use` has reached
/// the `vr_zones_epoch` of the publish (or once the engine is known to be stopped).
///
/// Voices sounding across the swap keep the zone parameters they captured at note-on, so a table
/// swap never changes a note in flight. A voice whose zone index no longer exists, or whose zone
/// now points at different sample memory, is faded out over `VR_DECLICK_MS` from its last output
/// value without reading the old buffers again — so a swap is click-free even if the old sample
/// memory is already gone.
///
/// Passing `count <= 0` or `zones == NULL` publishes an empty table: new note-ons are ignored.
void vr_set_zones(vr_engine_t *engine, const vr_zone_t *zones, int32_t count);

/// Serial number of the most recently published zone table. Starts at 0 before the first publish.
int64_t vr_zones_epoch(const vr_engine_t *engine);
/// Serial number of the zone table the audio thread most recently picked up. Once this reaches the
/// epoch a publish returned, no render can still be reading the table published before it.
int64_t vr_zones_epoch_in_use(const vr_engine_t *engine);

/// Pushes an event onto the single-producer single-consumer ring. Never blocks, never allocates,
/// never takes a lock; safe to call while the audio thread renders. Returns 0 on success and
/// non-zero when the queue is full, in which case the event is dropped and the drop counter
/// (`vr_dropped_events`) increments.
///
/// Events are consumed strictly in FIFO order, so push them in non-decreasing `frameTime` order:
/// an event scheduled beyond the current block holds back everything queued behind it until its
/// block arrives. Use `frameTime = 0` (or any past frame) for "as soon as possible".
int vr_push_event(vr_engine_t *engine, const vr_event_t *ev);

/// Renders one block. The only function that may be called on the audio thread.
///
/// Writes exactly `frameCount` frames into each of the first `channelCount` planes of
/// `outChannels` — the planes are overwritten, not added to. `startFrame` is the absolute frame
/// index of the first frame of the block and must advance by `frameCount` each call for event
/// timing to line up.
///
/// Per block it drains every due event and applies it at its exact sample offset, then for each
/// active voice reads its zone with linear interpolation at
/// `pitchRatio * sourceSampleRate / engineSampleRate`, applies the ADSR, the zone gain, the
/// velocity and an equal-power pan, honours loop points, and sums into the output. Voices that
/// finish free themselves.
///
/// Channel mapping: a mono zone is panned into the stereo pair, a stereo zone keeps its pair and
/// takes the pan as a balance, and zone channels past the second are not mixed. With
/// `channelCount == 1` the panned pair is folded to mono; output channels past the second are
/// written as silence.
void vr_render(vr_engine_t *engine,
               float *const *outChannels,
               int32_t channelCount,
               int32_t frameCount,
               int64_t startFrame);

/// Silences every voice immediately, empties the event queue, and clears the drop and steal
/// counters. Master gain returns to 1. The zone table and the frame timeline are left alone.
/// Call it when the audio thread is not rendering.
void vr_reset(vr_engine_t *engine);

/// Voices currently producing output, including declick tails. Snapshot; safe from any thread.
int32_t vr_active_voices(const vr_engine_t *engine);
/// Events dropped because the queue was full, since create or the last vr_reset. Tests assert 0.
int64_t vr_dropped_events(const vr_engine_t *engine);
/// Voices stolen because the pool was full, since create or the last vr_reset.
int64_t vr_stolen_voices(const vr_engine_t *engine);
/// Declick tails that had to be cut without a ramp because every tail slot was busy. Should stay 0
/// outside pathological stealing; a non-zero value means the pool is far too small for the part.
int64_t vr_hard_cuts(const vr_engine_t *engine);

/// Frames in the declick ramp at the engine's sample rate (`VR_DECLICK_MS`, rounded).
int32_t vr_declick_frames(const vr_engine_t *engine);

#ifdef __cplusplus
}
#endif

#endif
