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
//
// Around the insert, four more stages, in the order a player's rig has them:
//
//   pedal → insert → modulation → filter → pump
//
// The pedal. A wah: a resonant band-pass that a foot sweeps between about 400 Hz and 2.3 kHz —
// here the foot rocks in time, once every so many beats, the "wakka" of a funk rhythm part — or an
// envelope filter (a Mu-Tron III, the funk clavinet's), whose corner is opened by how hard the
// note is played and closes as it fades.
//
// The modulation. A chorus after the Roland Juno-60's: one bucket-brigade delay a side, 1.7 to
// 5.4 ms, swept in opposite directions by a triangle at 0.5 Hz (mode I) or 0.83 Hz (mode II),
// mixed with the dry signal, which is what makes a mono synth wide. A phaser after the MXR Phase
// 90's idea: six first-order all-passes swept together, with some of the output fed back, mixed
// with the dry so the notches move. A flanger: a short delay, 0.3 to 5 ms, swept slowly with
// feedback — the jet. A vibrato: the delay with no dry signal at all, which is a pitch wobble,
// the combo organ's.
//
// The filter. A low-pass or a high-pass of four poles, a pair of state-variable sections (the
// topology-preserving form, which stays well-behaved however fast its corner moves), with the
// second section's resonance raised as asked. Its corner is either the strip's own or, while a
// transport runs, what the song's timeline says for the section the playhead is in: held at one
// frequency, or swept from one to another across the section on a logarithmic path, which is how
// a DJ filter opens a build.
//
// The pump. The strip ducked every time the kick hits and let back up, as a compressor keyed from
// the kick would: down in two milliseconds by the depth asked, back on an exponential release.
// There is no kick signal in a strip to key from — the drums are a kit on their own strip — so the
// triggers are the kick's own steps, read from the grooves the song plays, and the song's clock
// says where they fall. That is the pump of French house, techno, afrobeats and lo-fi, on the beat
// to the sample, live or offline.
//
// The song's clock. Everything that keeps time is told the render sample time the transport's
// zero fell on and how many samples a beat lasts (`sfx_timeline_t`), and the render block passes
// each block's sample time (`sfx_process_at`). Before a transport is told, nothing keeps time: the
// filter sits at the strip's corner and the pump does nothing.

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

typedef enum {
    SFX_PEDAL_OFF = 0,
    /// Opened by how hard the note is played.
    SFX_PEDAL_ENVELOPE = 1,
    /// Rocked in time.
    SFX_PEDAL_WAH = 2,
} sfx_pedal_t;

typedef enum {
    SFX_MOD_OFF = 0,
    SFX_MOD_CHORUS = 1,
    SFX_MOD_PHASER = 2,
    SFX_MOD_FLANGER = 3,
    SFX_MOD_VIBRATO = 4,
} sfx_mod_t;

typedef enum {
    SFX_FILTER_OFF = 0,
    SFX_FILTER_LOWPASS = 1,
    SFX_FILTER_HIGHPASS = 2,
} sfx_filter_t;

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

    /// The pedal (`sfx_pedal_t`). Every stage fades its changes over 20 ms, as the insert does.
    int32_t pedal;
    /// The envelope filter's sensitivity, or the wah's sweep, 0…1.
    float pedalAmount;
    /// How sharp its peak is, 0…1.
    float pedalResonance;
    /// The wah: one rock of the foot, heel to toe and back, every this many beats.
    float pedalBeats;

    /// The modulation (`sfx_mod_t`).
    int32_t mod;
    /// Its sweep, in turns a second.
    float modRate;
    /// How far it sweeps, 0…1.
    float modDepth;
    /// The phaser's and the flanger's feedback, 0…0.9.
    float modFeedback;

    /// The filter (`sfx_filter_t`).
    int32_t filter;
    /// Its corner when no section moves it, Hz.
    float filterHz;
    /// 0 is a plain four-pole slope, 1 a sharp ringing peak at the corner.
    float filterResonance;

    /// The pump: 1 on, 0 off. Its triggers are the timeline's.
    int32_t pump;
    /// How far it ducks on a trigger, dB, when no section says otherwise.
    float pumpDB;
    /// How long it takes to come most of the way back, in beats.
    float pumpReleaseBeats;
} sfx_params_t;

/// How many sections a timeline holds, and how many triggers one section's pattern.
#define SFX_SEGMENTS 64
#define SFX_TRIGGERS 64

/// One section of the song as the strip's time-keeping stages read it, in transport beats.
typedef struct {
    float startBeat;
    float lengthBeats;
    /// The filter's corner across the section: from `filterFrom` at its first beat to `filterTo`
    /// at its end. Zero or less in `filterFrom` is the strip's own corner; `filterTo` equal to
    /// it (or zero or less) holds it.
    float filterFrom;
    float filterTo;
    /// How far the pump ducks here, dB: less than zero is the strip's own, zero is no pump here.
    float pumpDB;
    /// The pump's triggers: `count` offsets in beats into a pattern `patternBeats` long that
    /// repeats from the section's first beat. No triggers, no pump.
    float patternBeats;
    int32_t count;
    float at[SFX_TRIGGERS];
} sfx_segment_t;

/// The song's clock and its sections, for the stages that keep time.
typedef struct {
    /// 1 while a transport runs and the rest of this is true.
    int32_t valid;
    /// The render sample time of the transport's zero.
    double origin;
    double samplesPerBeat;
    /// The form comes round every this many beats, from beat 0; 0 is no loop.
    double cycleBeats;
    int32_t count;
    sfx_segment_t segments[SFX_SEGMENTS];
} sfx_timeline_t;

typedef struct sfx_state sfx_t;

/// A new insert, off. Nil when `sampleRate` is not positive or `channels` is not 1…8.
sfx_t *sfx_create(double sampleRate, int32_t channels);
void sfx_destroy(sfx_t *fx);
/// Silences every delay line and filter, puts the rotors where a fresh insert has them (at the
/// published speed, at rest angle), and adopts the published parameters without a fade.
void sfx_reset(sfx_t *fx);
/// Publishes a parameter set for the audio thread to pick up at its next block.
void sfx_set_params(sfx_t *fx, const sfx_params_t *params);
/// Publishes the song's clock and sections, as `sfx_set_params` does a parameter set. Safe while
/// the audio thread renders.
void sfx_set_timeline(sfx_t *fx, const sfx_timeline_t *timeline);
/// Processes `frames` frames of `channelCount` channels in place. Channels beyond the insert's
/// own are left as they are. With no sample time to keep it by, nothing keeps time.
void sfx_process(sfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames);
/// The same, the block's first frame at render sample time `sampleTime`, so the filter's
/// sections and the pump follow the song.
void sfx_process_at(sfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames, double sampleTime);

/// The rotors' present speeds in turns a second, for a test to watch them ease.
void sfx_rotor_speeds(const sfx_t *fx, float *horn, float *drum);
/// The filter's corner as it was last played, Hz, for a test to watch it sweep; 0 when off.
float sfx_filter_corner(const sfx_t *fx);


// MARK: - The returns
//
// What the two returns every strip sends to can be besides Apple's reverb and delay. Each return
// holds one of these before its Apple unit; when it is in use, that unit is bypassed and this is
// the return.
//
// A spring. The reverb in a guitar amp and on the drums of a reggae record: a long coil a
// transducer shakes at one end and a pickup hears at the other. Sound travels along a spring at a
// speed that depends on its pitch, low frequencies slower, so every hit comes back as a chirp —
// the "boing" — and keeps coming back as it reflects end to end. Modelled as Parker's dispersive
// loop: a cascade of first-order all-passes (the frequency-dependent delay that is the chirp)
// inside a feedback delay as long as the trip down the spring, darkened and thinned each time
// round. Two springs a side, of different lengths, as a tank has.
// Source: J. Parker, "Efficient Dispersion Generation Structures for Spring Reverb Emulation",
// EURASIP J. on Advances in Signal Processing, 2011; Accutronics tank delay figures (~30–45 ms).
//
// A gated room. The eighties drum sound: a bright, dense room cut off a quarter of a second after
// every hit rather than left to die away — the AMS RMX16's "nonlinear" programme, and before it a
// noise gate on the room microphones keyed by the snare. A small feedback delay network makes the
// room; a gate opened by each transient in what is sent to it closes the room again.
//
// A tape echo. The Echoplex and the Roland Space Echo: a loop of tape with a record head and a
// playback head, so the repeats wow and flutter as the tape's speed wanders, each one is darker
// and thinner than the last (the loop's EQ), and they saturate rather than clip as feedback is
// pushed — which is how a dub mix spirals an echo up into a scream and back. A change of time
// glides, as moving the head does, bending the repeats' pitch.

typedef enum {
    RFX_OFF = 0,
    RFX_SPRING = 1,
    RFX_GATED = 2,
    RFX_TAPE = 3,
} rfx_kind_t;

typedef struct {
    /// What the return is (`rfx_kind_t`). A change fades over 20 ms.
    int32_t kind;
    /// The spring's ring, 0 short … 1 long; the gated room's hold, in seconds.
    float decay;
    /// The spring's and the tape's high cut, Hz.
    float toneHz;
    /// The tape: seconds between repeats.
    float delaySeconds;
    /// The tape: how much of each repeat comes round again, 0…0.95.
    float feedback;
    /// The tape: how much its speed wanders, 0…1.
    float wow;
} rfx_params_t;

typedef struct rfx_state rfx_t;

/// A new return, off. Nil when `sampleRate` is not positive or `channels` is not 1…2.
rfx_t *rfx_create(double sampleRate, int32_t channels);
void rfx_destroy(rfx_t *fx);
void rfx_reset(rfx_t *fx);
void rfx_set_params(rfx_t *fx, const rfx_params_t *params);
/// In place. Off, the signal passes as it came.
void rfx_process(rfx_t *fx, float *const *channels, int32_t channelCount, int32_t frames);

#ifdef __cplusplus
}
#endif

#endif
