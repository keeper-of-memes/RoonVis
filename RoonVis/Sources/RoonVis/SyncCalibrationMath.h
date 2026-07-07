#pragma once

namespace RoonVis
{

// Computes the audio-delay TARGET to persist after sync calibration so that
// the A/V latency lock's steady-state trim lands the EFFECTIVE delay back on
// the value the user converged to by ear.
//
// The lock computes: effective = clamp(target + kNominal − avgRender − avgSwap,
// [kMinAdaptiveBuffer, target]), i.e. effective = target − max(0, R+S−kNominal).
// Inverting: target = draft + max(0, avgRenderMs + avgSwapMs − kNominal).
//
// The result is snapped to the settings' 5 ms step and clamped to [0, 500].
// Note: below the lock's 100 ms adaptive floor the inverse is best-effort
// (the floor caps how the trim behaves); callers/docs should treat sub-100 ms
// drafts accordingly.
long SyncCalibrationSaveTarget(long draftMs, double avgRenderMs, double avgSwapMs);

} // namespace RoonVis
