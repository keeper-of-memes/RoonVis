#include "TestHarness.h"

#include "AudioOnsetDetector.h"
#include "SyncCalibrationMath.h"

#include <cmath>
#include <cstdlib>
#include <vector>

using namespace RoonVis;

namespace
{

constexpr unsigned kRate = 44100;
constexpr unsigned kChannels = 2;

// Deterministic pseudo-noise (no rand(): keep tests reproducible).
int16_t Noise(size_t i, int16_t amplitude)
{
    const uint32_t x = static_cast<uint32_t>(i) * 2654435761u;
    return static_cast<int16_t>(static_cast<int32_t>(x % (2 * amplitude + 1)) - amplitude);
}

// Builds an interleaved stereo buffer: low-amplitude noise floor with optional
// sine bursts of `burstHz` at the given start frames.
std::vector<int16_t> BuildSignal(size_t totalFrames,
                                 const std::vector<size_t> &burstStarts,
                                 double burstHz,
                                 size_t burstFrames,
                                 int16_t burstAmplitude,
                                 int16_t noiseAmplitude)
{
    std::vector<int16_t> samples(totalFrames * kChannels);
    for (size_t frame = 0; frame < totalFrames; frame++)
    {
        double value = Noise(frame, noiseAmplitude);
        for (const size_t start : burstStarts)
        {
            if (frame >= start && frame < start + burstFrames)
            {
                const double t = static_cast<double>(frame - start) / kRate;
                value += burstAmplitude * std::sin(2.0 * 3.14159265358979323846 * burstHz * t);
            }
        }
        const int16_t sample = static_cast<int16_t>(std::max(-32768.0, std::min(32767.0, value)));
        samples[frame * kChannels] = sample;
        samples[frame * kChannels + 1] = sample;
    }
    return samples;
}

// Feeds the signal in render-loop-sized chunks (~735 frames = 60fps at 44.1k),
// returning the chunk indexes where onsets fired.
std::vector<size_t> RunDetector(AudioOnsetDetector &detector, const std::vector<int16_t> &samples)
{
    const size_t chunkFrames = 735;
    const size_t totalFrames = samples.size() / kChannels;
    std::vector<size_t> onsets;
    for (size_t start = 0, chunk = 0; start < totalFrames; start += chunkFrames, chunk++)
    {
        const size_t frames = std::min(chunkFrames, totalFrames - start);
        if (detector.ProcessChunk(samples.data() + start * kChannels, frames))
        {
            onsets.push_back(chunk);
        }
    }
    return onsets;
}

void TestKickPatternDetected()
{
    AudioOnsetDetector detector;
    detector.Configure(kRate, kChannels);

    // 4 bass bursts (80 Hz, 80 ms) at 500 ms spacing over a noise floor.
    const size_t half = kRate / 2;
    auto samples = BuildSignal(kRate * 3, {half, 2 * half, 3 * half, 4 * half}, 80.0, kRate * 80 / 1000, 12000, 300);
    auto onsets = RunDetector(detector, samples);

    REQUIRE(onsets.size() == 4);
    // Each onset lands near its burst start (chunk 30 = 500 ms at 735-frame chunks).
    for (size_t i = 0; i < onsets.size(); i++)
    {
        const size_t expectedChunk = (half * (i + 1)) / 735;
        CHECK(onsets[i] >= expectedChunk && onsets[i] <= expectedChunk + 2);
    }
}

void TestSilenceNoOnsets()
{
    AudioOnsetDetector detector;
    detector.Configure(kRate, kChannels);
    std::vector<int16_t> silence(kRate * 2 * kChannels, 0);
    CHECK(RunDetector(detector, silence).empty());
}

void TestConstantToneAtMostOne()
{
    AudioOnsetDetector detector;
    detector.Configure(kRate, kChannels);
    auto samples = BuildSignal(kRate * 2, {0}, 80.0, kRate * 2, 12000, 0);
    auto onsets = RunDetector(detector, samples);
    CHECK(onsets.size() <= 1); // the leading edge may fire; the sustain must not
}

void TestHighFrequencyRejected()
{
    AudioOnsetDetector detector;
    detector.Configure(kRate, kChannels);
    // 5 kHz bursts (hi-hat-like) must not fire the bass-band detector.
    const size_t half = kRate / 2;
    auto samples = BuildSignal(kRate * 2, {half, 2 * half, 3 * half}, 5000.0, kRate * 30 / 1000, 12000, 300);
    CHECK(RunDetector(detector, samples).empty());
}

void TestRefractorySuppresssDoubles()
{
    AudioOnsetDetector detector;
    detector.Configure(kRate, kChannels);
    // Two bursts 100 ms apart: inside the 200 ms refractory -> only one onset.
    auto samples = BuildSignal(kRate, {kRate / 2, kRate / 2 + kRate / 10}, 80.0, kRate * 50 / 1000, 12000, 300);
    auto onsets = RunDetector(detector, samples);
    CHECK(onsets.size() == 1);
}

void TestSaveTargetMath()
{
    // Fast render (below the 5 ms nominal): zero trim, exact passthrough.
    CHECK(SyncCalibrationSaveTarget(200, 2.0, 0.5) == 200);
    // A15-scale: ~7.7ms render + ~0.3 swap -> trim 3 -> 203 snaps to 205.
    CHECK(SyncCalibrationSaveTarget(200, 7.7, 0.3) == 205);
    // A8-scale: ~25ms render + 0.3 swap -> trim ~20.3 -> 220.
    CHECK(SyncCalibrationSaveTarget(200, 25.0, 0.3) == 220);
    // Snapping.
    CHECK(SyncCalibrationSaveTarget(198, 2.0, 0.0) == 200);
    // Clamping.
    CHECK(SyncCalibrationSaveTarget(495, 30.0, 0.0) == 500);
    CHECK(SyncCalibrationSaveTarget(0, 0.0, 0.0) == 0);
    // Garbage inputs treated as zero trim.
    CHECK(SyncCalibrationSaveTarget(100, -5.0, 0.0) == 100);
    // Sub-100 ms draft on A8-scale render: math still monotone (50+20=70),
    // but post-save convergence is best-effort because the lock's 100 ms
    // adaptive floor caps the trim behaviour below 100 ms (documented).
    CHECK(SyncCalibrationSaveTarget(50, 25.0, 0.3) == 70);
}

} // namespace

void RunAudioOnsetDetectorTests()
{
    TestKickPatternDetected();
    TestSilenceNoOnsets();
    TestConstantToneAtMostOne();
    TestHighFrequencyRejected();
    TestRefractorySuppresssDoubles();
    TestSaveTargetMath();
}
