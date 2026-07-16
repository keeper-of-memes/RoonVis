#include "PresetDwellPlan.h"

namespace RoonVis
{

PresetDwellPlan ComputeDwellPlan(size_t nextIndex, const std::string& nextPath,
                                 double lastSwitchTime, double rotationInterval,
                                 double smoothWindow, double settleSeconds,
                                 double minLeadSeconds)
{
    PresetDwellPlan plan;

    // HOLD / nothing eligible: rotation returned no next preset.
    if (nextIndex == SIZE_MAX)
    {
        plan.state = PresetDwellPlan::State::Exhausted;
        return plan;
    }

    const double settleWindow = smoothWindow + settleSeconds;

    // The interval must fit the settle window AND still leave the required lead before the
    // next scheduled switch, or preloading this dwell is pointless — fall back to the
    // normal load path. (Legacy: rotationInterval - settleWindow < minLead -> NO.)
    if (rotationInterval - settleWindow < minLeadSeconds)
    {
        plan.state = PresetDwellPlan::State::Exhausted;
        return plan;
    }

    // No switch yet: the legacy guard refused to warm until a real switch established a
    // switch time. Stay Exhausted; the recompute at the first confirm re-arms with a real
    // notBeforeTime.
    if (lastSwitchTime <= 0)
    {
        plan.state = PresetDwellPlan::State::Exhausted;
        return plan;
    }

    plan.state = PresetDwellPlan::State::Armed;
    plan.targetIndex = nextIndex;
    plan.targetPath = nextPath;
    plan.notBeforeTime = lastSwitchTime + settleWindow;
    return plan;
}

bool DwellPlanReady(const PresetDwellPlan& plan, double now)
{
    return plan.state == PresetDwellPlan::State::Armed && now >= plan.notBeforeTime;
}

}  // namespace RoonVis
