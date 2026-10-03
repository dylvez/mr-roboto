#include "CSignalsmithStretch.h"

// The vendored header is warning-clean for its own build; SwiftPM adds -Wshorten-64-to-32.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include "signalsmith-stretch/signalsmith-stretch.h"
#pragma clang diagnostic pop

#include <new>

struct ss_stretch {
    signalsmith::stretch::SignalsmithStretch<float> impl;
    int channels = 0;
    double sampleRate = 0;
    double timeFactor = 1;

    explicit ss_stretch(long seed) : impl(seed) {}
    ss_stretch() : impl() {}
};

extern "C" {

ss_stretch_t *ss_stretch_create(int channels, double sampleRate, ss_stretch_preset preset, long seed) {
    if (channels < 1 || !(sampleRate > 0)) return nullptr;
    ss_stretch_t *s = seed != 0 ? new (std::nothrow) ss_stretch(seed) : new (std::nothrow) ss_stretch();
    if (!s) return nullptr;
    s->channels = channels;
    s->sampleRate = sampleRate;
    switch (preset) {
    case SS_STRETCH_PRESET_CHEAPER:
        s->impl.presetCheaper(channels, float(sampleRate), /*splitComputation=*/false);
        break;
    case SS_STRETCH_PRESET_DEFAULT:
    default:
        s->impl.presetDefault(channels, float(sampleRate), /*splitComputation=*/false);
        break;
    }
    return s;
}

ss_stretch_t *ss_stretch_create_configured(int channels, double sampleRate, int blockSamples, int intervalSamples, long seed) {
    if (channels < 1 || !(sampleRate > 0) || blockSamples < 2 || intervalSamples < 1 || intervalSamples > blockSamples) return nullptr;
    ss_stretch_t *s = seed != 0 ? new (std::nothrow) ss_stretch(seed) : new (std::nothrow) ss_stretch();
    if (!s) return nullptr;
    s->channels = channels;
    s->sampleRate = sampleRate;
    s->impl.configure(channels, blockSamples, intervalSamples, /*splitComputation=*/false);
    return s;
}

void ss_stretch_destroy(ss_stretch_t *s) { delete s; }

void ss_stretch_reset(ss_stretch_t *s) { s->impl.reset(); }

int ss_stretch_channels(const ss_stretch_t *s) { return s->channels; }
double ss_stretch_sample_rate(const ss_stretch_t *s) { return s->sampleRate; }
int ss_stretch_block_samples(const ss_stretch_t *s) { return s->impl.blockSamples(); }
int ss_stretch_interval_samples(const ss_stretch_t *s) { return s->impl.intervalSamples(); }
int ss_stretch_input_latency(const ss_stretch_t *s) { return s->impl.inputLatency(); }
int ss_stretch_output_latency(const ss_stretch_t *s) { return s->impl.outputLatency(); }

void ss_stretch_set_time_factor(ss_stretch_t *s, double factor) {
    if (factor > 0) s->timeFactor = factor;
}
double ss_stretch_time_factor(const ss_stretch_t *s) { return s->timeFactor; }

void ss_stretch_set_transpose_semitones(ss_stretch_t *s, double semitones, double tonalityLimitHz) {
    float limit = tonalityLimitHz > 0 ? float(tonalityLimitHz / s->sampleRate) : 0.0f;
    s->impl.setTransposeSemitones(float(semitones), limit);
}

void ss_stretch_set_formant_semitones(ss_stretch_t *s, double semitones, bool compensatePitch) {
    s->impl.setFormantSemitones(float(semitones), compensatePitch);
}

void ss_stretch_set_formant_base(ss_stretch_t *s, double baseHz) {
    s->impl.setFormantBase(baseHz > 0 ? float(baseHz / s->sampleRate) : 0.0f);
}

void ss_stretch_process(ss_stretch_t *s, const float *const *input, int inSamples,
                        float *const *output, int outSamples) {
    s->impl.process(input, inSamples, output, outSamples);
}

void ss_stretch_seek(ss_stretch_t *s, const float *const *input, int inSamples, double playbackRate) {
    s->impl.seek(input, inSamples, playbackRate);
}

int ss_stretch_seek_length(const ss_stretch_t *s) { return s->impl.seekLength(); }

void ss_stretch_flush(ss_stretch_t *s, float *const *output, int outSamples) {
    s->impl.flush(output, outSamples, float(1.0 / s->timeFactor));
}

bool ss_stretch_exact(ss_stretch_t *s, const float *const *input, int inSamples,
                      float *const *output, int outSamples) {
    if (inSamples <= 0 || outSamples <= 0) return false;
    return s->impl.exact(input, inSamples, output, outSamples);
}

int ss_stretch_exact_minimum_input(const ss_stretch_t *s, double playbackRate) {
    return s->impl.outputSeekLength(float(playbackRate));
}

void ss_stretch_output_seek(ss_stretch_t *s, const float *const *input, int inputLength) {
    s->impl.outputSeek(input, inputLength);
}

} // extern "C"
