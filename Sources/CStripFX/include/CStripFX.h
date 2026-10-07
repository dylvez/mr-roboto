// A mixer strip's insert: what sits between a part's sources and its EQ when the part is an
// electric guitar through an amp, or an organ through a rotating speaker.
//
// In C for the reason the render core and the degradation chain are: the insert runs inside an
// audio unit's render block, and on macOS 27 Swift is not supported on realtime audio threads.
// Swift owns every allocation and every lifetime; `sfx_process` allocates nothing, takes no lock,
// reads no clock and calls nothing outside this file. It is deterministic: two runs over the same
// input from a reset state are byte-identical, which is what makes a bounce the mix.
//
// Thread model (two roles, as in CDegrade):
//   * owner thread — sfx_create / sfx_destroy / sfx_reset / sfx_set_params.
//   * audio thread — sfx_process, and nothing else. sfx_set_params is safe to call while it runs:
//                    parameters are published through a ring of slots and one release store, and
//                    picked up at the top of the next block.
//
// Audio is planar float: `channels[c]` points at `frames` samples of channel `c`, processed in
// place.
//
//
// MARK: - What is modelled
//
// The amp. A guitar amplifier and its speaker, the half of an electric guitar's sound the string
// does not make. A preamp that rounds a clean signal and, driven, clips it asymmetrically (a
// triode clips its two half-cycles differently, which is the even harmonics of "warm"); a tone
// control that tilts the spectrum about the middle; and the speaker cabinet, which is the part
// that makes distortion sound like a guitar rather than a fuzz pedal into a mixing desk: nothing
// under about 80 Hz, nothing much over 5 kHz, a presence bump near 2 kHz and the box's
// honk scooped out near 400. The cabinet is a fixed set of filters, not a measured response.
// The drive is oversampled twice, so the harmonics a hard clip makes above the original Nyquist
// are filtered before they fold back.
//
// The rotating speaker. A Leslie 122's two rotors, as the organ is heard through one: a crossover
// near 800 Hz, the treble on a spinning horn and the bass into a spinning drum. The horn is heard
// from two microphones a third of a turn apart, each hearing it approach and recede (a pitch
// swing, a delay modulated by about ±0.4 ms, the horn's radius over the speed of sound), louder
// and brighter when it faces the microphone; the drum is mostly a slower swell of level. Slow
// ("chorale") is about 0.8 turns a second on the horn and 0.7 on the drum; fast ("tremolo") about
// 6.8 and 5.9. The rotors do not jump between speeds: the light horn gets there in under a second
// and the heavy drum takes several, which is the sound of the speed switch.
// Sources: Leslie 122 service data as widely reproduced (crossover 800 Hz; horn and drum speeds
// for chorale and tremolo); the horn's doppler swing follows from its radius (~0.15 m).

#ifndef CSTRIPFX_H
#define CSTRIPFX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SFX_OFF = 0,
    SFX_AMP = 1,
    SFX_ROTARY = 2,
} sfx_kind_t;

typedef struct {
    /// What is inserted (`sfx_kind_t`). A change fades the old out and the new in over 20 ms.
    int32_t kind;
    /// The amp's gain before the clipping stage, 0 (clean, the cabinet alone) to 1 (a lead).
    float drive;
    /// The amp's tone, 0 dark to 1 bright; 0.5 is flat.
    float tone;
    /// The rotors' speed: 0 slow (chorale), 1 fast (tremolo). The rotors ease toward it.
    float fast;
    /// The rotating speaker's own preamp, driven: 0 clean, 1 growling.
    float growl;
    /// Output gain, linear. 1 is unity.
    float level;
} sfx_params_t;

typedef struct sfx_state sfx_t;

/// A new insert, off. Nil when `sampleRate` is not positive or `channels` is not 1…8.
sfx_t *sfx_create(double sampleRate, int32_t channels);
void sfx_destroy(sfx_t *fx);
/// Silences every delay line and filter, puts the rotors where a fresh insert has them (at the
/// published speed, at rest angle), and adopts the published parameters without a fade.
void sfx_reset(sfx_t *fx);
/// Publishes a parameter set for the audio thread to pick up at its next block.
void sfx_set_params(sfx_t *fx, const sfx_params_t *params);
/// Processes `frames` frames of `channelCount` channels in place. Channels beyond the insert's
/// own are left as they are.
void sfx_process(sfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames);

/// The rotors' present speeds in turns a second, for a test to watch them ease.
void sfx_rotor_speeds(const sfx_t *fx, float *horn, float *drum);

#ifdef __cplusplus
}
#endif

#endif
