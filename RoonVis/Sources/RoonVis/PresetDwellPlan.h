#pragma once

#include <cstddef>
#include <string>

namespace RoonVis
{

// A dwell plan encodes, ONCE per confirm/recompute event, the answer to the
// per-frame question the legacy warm path re-derived every frame: "is there a next
// preset to preload, and from what time is it eligible?" The render loop then reduces
// to a single time comparison (DwellPlanReady) for the rest of the dwell instead of
// re-walking the rotation and re-checking windows on every frame.
//
// State machine (main/GL thread only, like all rotation state):
//   Idle       — no plan computed yet (default), or nothing to preload.
//   Armed      — a next preset exists and fits the interval; warm it once now >= notBeforeTime.
//   Satisfied  — the preload for `targetIndex`/`targetPath` succeeded; nothing more to do
//                this dwell. Set by the render path on a successful warm.
//   Exhausted  — no preload is possible this dwell. Either the rotation interval can't fit a
//                budgeted preload, rotation is on HOLD (nextIndex == SIZE_MAX), OR a warm
//                attempt failed. In every case the plan does NOT retry until the next
//                recompute event replaces it (see the failed-warm equivalence note below).
struct PresetDwellPlan
{
    enum class State
    {
        Idle,
        Armed,
        Satisfied,
        Exhausted,
    };

    State state = State::Idle;
    size_t targetIndex = SIZE_MAX;
    std::string targetPath;
    double notBeforeTime = 0.0;
};

// Encodes the settle/lead math the legacy canWarmPresetAtTime performed:
//   settleWindow  = smoothWindow + settleSeconds
//   eligible when now - lastSwitchTime >= settleWindow AND
//                 rotationInterval - settleWindow >= minLeadSeconds
// smoothWindow is the crossfade seconds when the transition is a smooth cut (0 for an
// instant cut); the caller passes it in already resolved (including any perf-sweep
// override) so this core stays free of Apple/env reads.
//
// Returns:
//   Exhausted — when the interval can't fit a preload (rotationInterval - settleWindow <
//               minLeadSeconds) OR nextIndex == SIZE_MAX (rotation on HOLD / nothing
//               eligible). notBeforeTime is 0 and targetPath empty.
//   Exhausted — when lastSwitchTime <= 0 (no switch has happened yet). The legacy guard
//               refused to warm until the first real switch established a switch time; a
//               recompute at that first confirm re-arms the plan with a real notBeforeTime.
//               (Without this, notBeforeTime would collapse to the tiny settleWindow and a
//               large CACurrentMediaTime `now` would go ready prematurely.)
//   Armed     — otherwise: targetIndex/targetPath set to the next preset, notBeforeTime =
//               lastSwitchTime + settleWindow.
PresetDwellPlan ComputeDwellPlan(size_t nextIndex, const std::string& nextPath,
                                 double lastSwitchTime, double rotationInterval,
                                 double smoothWindow, double settleSeconds,
                                 double minLeadSeconds);

// The entire per-frame cost: one comparison. Ready iff the plan is Armed and the settle
// window has elapsed. Satisfied/Exhausted/Idle are never ready — a Satisfied preload is
// done and an Exhausted plan must not retry until a recompute replaces it.
bool DwellPlanReady(const PresetDwellPlan& plan, double now);

}  // namespace RoonVis
