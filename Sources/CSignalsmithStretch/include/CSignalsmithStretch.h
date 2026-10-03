// C shim over Signalsmith Stretch (vendored under ../vendor, MIT) so Swift can use it without
// C++ interop. One handle wraps one signalsmith::stretch::SignalsmithStretch<float>.
//
// Audio is planar float: `input[c]` / `output[c]` point at `channels` arrays of samples.
// Handles are not thread-safe; use one per stretch job.
#ifndef C_SIGNALSMITH_STRETCH_H
#define C_SIGNALSMITH_STRETCH_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ss_stretch ss_stretch_t;

typedef enum ss_stretch_preset {
    /// presetDefault: 120 ms blocks, 30 ms interval.
    SS_STRETCH_PRESET_DEFAULT = 0,
    /// presetCheaper: 100 ms blocks, 40 ms interval.
    SS_STRETCH_PRESET_CHEAPER = 1,
} ss_stretch_preset;

/// Creates a stretcher configured with `preset` for `channels` channels at `sampleRate`.
/// `seed` fixes the phase-randomisation engine so runs are reproducible (0 = seed from
/// std::random_device). Returns NULL on invalid arguments.
ss_stretch_t *ss_stretch_create(int channels, double sampleRate, ss_stretch_preset preset, long seed);
/// Like `ss_stretch_create` but with an explicit STFT block length and hop (samples), the
/// library's `configure`. Shorter blocks keep transients sharper at the cost of low-frequency
/// resolution. Returns NULL on invalid arguments.
ss_stretch_t *ss_stretch_create_configured(int channels, double sampleRate, int blockSamples, int intervalSamples, long seed);
void ss_stretch_destroy(ss_stretch_t *stretch);

/// Clears internal buffers and band state, keeping the configuration and settings.
void ss_stretch_reset(ss_stretch_t *stretch);

int ss_stretch_channels(const ss_stretch_t *stretch);
double ss_stretch_sample_rate(const ss_stretch_t *stretch);
int ss_stretch_block_samples(const ss_stretch_t *stretch);
int ss_stretch_interval_samples(const ss_stretch_t *stretch);
/// Samples of input the processing position lags the supplied input by.
int ss_stretch_input_latency(const ss_stretch_t *stretch);
/// Samples of output that lag the processing position.
int ss_stretch_output_latency(const ss_stretch_t *stretch);

/// Time-stretch factor = output duration / input duration (1.25 = 25 percent longer). The library
/// infers the rate from the relative block sizes handed to process(), so this is stored for
/// `ss_stretch_flush` (which needs the playback rate to extrapolate) and for callers that want a
/// single source of truth.
void ss_stretch_set_time_factor(ss_stretch_t *stretch, double factor);
double ss_stretch_time_factor(const ss_stretch_t *stretch);

/// Pitch shift in semitones. `tonalityLimitHz` > 0 switches to a non-linear frequency map above
/// that frequency, which preserves more of the timbre; 0 keeps a plain multiply.
void ss_stretch_set_transpose_semitones(ss_stretch_t *stretch, double semitones, double tonalityLimitHz);

/// Formant shift in semitones (0 = leave formants alone). With `compensatePitch` the formant
/// envelope is also corrected for the transpose set above, i.e. pitch-shift with formants kept.
void ss_stretch_set_formant_semitones(ss_stretch_t *stretch, double semitones, bool compensatePitch);
/// Rough fundamental (Hz) used by the formant analysis; 0 = detect.
void ss_stretch_set_formant_base(ss_stretch_t *stretch, double baseHz);

/// Feeds `inSamples` of input and produces `outSamples` of output. The ratio of the two is the
/// stretch for this call. Input and output must not alias.
void ss_stretch_process(ss_stretch_t *stretch,
                        const float *const *input, int inSamples,
                        float *const *output, int outSamples);

/// Pre-rolls the input position without producing output. Give it `ss_stretch_seek_length`
/// samples ideally; `playbackRate` = input samples per output sample (1 / time factor).
void ss_stretch_seek(ss_stretch_t *stretch, const float *const *input, int inSamples, double playbackRate);
int ss_stretch_seek_length(const ss_stretch_t *stretch);

/// Drains the remaining output with no further input, using the stored time factor to
/// extrapolate when `outSamples` exceeds one interval. Resets the STFT afterwards.
void ss_stretch_flush(ss_stretch_t *stretch, float *const *output, int outSamples);

/// Offline, time-aligned stretch of a whole buffer: output[t * outSamples / inSamples] lines up
/// with input[t]. Uses the library's own seek + process + flush sequence (`exact`). Returns
/// false (and zeroes the output) when the input is shorter than the seek pre-roll,
/// `ss_stretch_exact_minimum_input`.
bool ss_stretch_exact(ss_stretch_t *stretch,
                      const float *const *input, int inSamples,
                      float *const *output, int outSamples);
/// Smallest input `ss_stretch_exact` accepts for `playbackRate` = inSamples / outSamples.
int ss_stretch_exact_minimum_input(const ss_stretch_t *stretch, double playbackRate);

/// Resets, then moves the input position to the start of `input` *and* pre-computes output, so
/// the next samples `ss_stretch_process` returns are aligned to the input's first sample. The
/// playback rate is inferred from `inputLength`: hand it `inputLatency + rate × outputLatency`
/// samples. What `ss_stretch_exact` does first; exported so a stretch whose rate varies can do
/// the same and then feed `ss_stretch_process` at its own rate, chunk by chunk.
void ss_stretch_output_seek(ss_stretch_t *stretch, const float *const *input, int inputLength);

#ifdef __cplusplus
}
#endif

#endif
