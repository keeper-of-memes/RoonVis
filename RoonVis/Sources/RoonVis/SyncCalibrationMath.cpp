#include "SyncCalibrationMath.h"

#include <algorithm>
#include <cmath>

namespace RoonVis
{

namespace
{
// Mirrors the latency lock's kNominalRenderMs (ANGLEGLView+Diagnostics.mm) and
// the settings range/step for audioInputDelayMs (RoonVisSettings.mm).
constexpr double kNominalRenderMs = 5.0;
constexpr long kDelayMinimumMs = 0;
constexpr long kDelayMaximumMs = 500;
constexpr long kDelayStepMs = 5;
} // namespace

long SyncCalibrationSaveTarget(long draftMs, double avgRenderMs, double avgSwapMs)
{
    const double render = std::isfinite(avgRenderMs) && avgRenderMs > 0.0 ? avgRenderMs : 0.0;
    const double swap = std::isfinite(avgSwapMs) && avgSwapMs > 0.0 ? avgSwapMs : 0.0;
    const double trim = std::max(0.0, render + swap - kNominalRenderMs);
    const double target = static_cast<double>(draftMs) + trim;

    long snapped = static_cast<long>(std::lround(target / static_cast<double>(kDelayStepMs))) * kDelayStepMs;
    return std::max(kDelayMinimumMs, std::min(kDelayMaximumMs, snapped));
}

} // namespace RoonVis
