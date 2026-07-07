#include "AudioOnsetDetector.h"

#include <cmath>

namespace RoonVis
{

void AudioOnsetDetector::Configure(unsigned sampleRate, unsigned channels)
{
    sampleRate_ = sampleRate > 0 ? sampleRate : 44100;
    channels_ = channels > 0 ? channels : 2;
    // 1st-order IIR low-pass: alpha = dt / (RC + dt), RC = 1/(2*pi*fc).
    const double dt = 1.0 / static_cast<double>(sampleRate_);
    const double rc = 1.0 / (2.0 * 3.14159265358979323846 * kBassCutoffHz);
    lowpassAlpha_ = dt / (rc + dt);
    // Per-frame EMA factor so the baseline decays with ~kBaselineDecaySeconds.
    baselineAlphaPerFrame_ = 1.0 - std::exp(-dt / kBaselineDecaySeconds);
    Reset();
}

void AudioOnsetDetector::Reset()
{
    lowpassState1_ = 0.0;
    lowpassState2_ = 0.0;
    baseline_ = 0.0;
    baselinePrimed_ = false;
    armed_ = true;
    secondsSinceOnset_ = 1e9;
}

bool AudioOnsetDetector::ProcessChunk(const int16_t *interleaved, size_t frames)
{
    if (interleaved == nullptr || frames == 0)
    {
        return false;
    }

    // Bass-band mean-square energy of the chunk, updating the running EMA
    // baseline per frame so short chunks and long chunks behave alike.
    double chunkEnergyAccum = 0.0;
    double baseline = baseline_;
    double lp1 = lowpassState1_;
    double lp2 = lowpassState2_;
    for (size_t frame = 0; frame < frames; frame++)
    {
        double mono = 0.0;
        for (unsigned channel = 0; channel < channels_; channel++)
        {
            mono += static_cast<double>(interleaved[frame * channels_ + channel]);
        }
        mono /= static_cast<double>(channels_);

        // Two cascaded poles: ~40 dB down at 5 kHz vs ~20 dB for one pole,
        // which is the difference between hi-hats firing and not.
        lp1 += lowpassAlpha_ * (mono - lp1);
        lp2 += lowpassAlpha_ * (lp1 - lp2);
        const double energy = lp2 * lp2;
        chunkEnergyAccum += energy;
        baseline += baselineAlphaPerFrame_ * (energy - baseline);
    }
    lowpassState1_ = lp1;
    lowpassState2_ = lp2;

    const double chunkSeconds = static_cast<double>(frames) / static_cast<double>(sampleRate_);
    const double chunkEnergy = chunkEnergyAccum / static_cast<double>(frames);
    secondsSinceOnset_ += chunkSeconds;

    // Re-arm hysteresis: after firing, require the energy to fall back near the
    // baseline before another onset is allowed, so a sustained tone fires once
    // at its leading edge instead of once per refractory window while the EMA
    // catches up.
    if (!armed_ && chunkEnergy < kRearmRatio * baseline_)
    {
        armed_ = true;
    }

    bool fired = false;
    if (baselinePrimed_ &&
        armed_ &&
        chunkEnergy > kSilenceFloor &&
        chunkEnergy > kOnsetRatio * baseline_ && // compare against the PRE-chunk baseline
        secondsSinceOnset_ >= kRefractorySeconds)
    {
        fired = true;
        armed_ = false;
        secondsSinceOnset_ = 0.0;
    }

    baseline_ = baseline;
    baselinePrimed_ = true;
    return fired;
}

} // namespace RoonVis
