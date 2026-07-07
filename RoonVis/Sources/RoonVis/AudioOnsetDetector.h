#pragma once

#include <cstddef>
#include <cstdint>

namespace RoonVis
{

// Bass-band audio onset detector for the sync-calibration pulse. This is
// deliberately onset detection, NOT beat tracking: it fires on bass hits
// (kicks) and ignores hi-hats and sustained content by design. Pure C++,
// no I/O; host-testable.
//
// Feed it the exact chunks handed to projectM (post delay-buffer,
// pre-sensitivity scaling) so a detected onset is time-aligned with what the
// visualizer renders.
class AudioOnsetDetector
{
public:
    // Tuning constants (named for cheap adjustment after device sessions).
    static constexpr double kBassCutoffHz = 150.0;      // 1st-order low-pass corner
    static constexpr double kBaselineDecaySeconds = 1.0; // EMA time constant for the energy baseline
    static constexpr double kOnsetRatio = 2.5;           // chunk energy must exceed ratio x baseline
    static constexpr double kRearmRatio = 1.2;           // energy must fall below ratio x baseline to re-arm
    static constexpr double kSilenceFloor = 1.0e6;       // mean-square (int16^2 units) below which nothing fires
    static constexpr double kRefractorySeconds = 0.2;    // minimum spacing between onsets

    void Configure(unsigned sampleRate, unsigned channels);
    void Reset();

    // Processes one interleaved int16 chunk; returns true when an onset fires
    // within it. `frames` counts per-channel sample frames.
    bool ProcessChunk(const int16_t *interleaved, size_t frames);

private:
    unsigned sampleRate_ = 44100;
    unsigned channels_ = 2;
    double lowpassState1_ = 0.0; // two cascaded 1st-order poles for usable HF rejection
    double lowpassState2_ = 0.0;
    double lowpassAlpha_ = 0.0;
    bool armed_ = true; // re-arm hysteresis: sustained tones fire once, not per refractory window
    double baseline_ = 0.0;
    double baselineAlphaPerFrame_ = 0.0;
    double secondsSinceOnset_ = 1e9; // starts "long ago" so the first hit can fire
    bool baselinePrimed_ = false;
};

} // namespace RoonVis
