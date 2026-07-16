#include "TestHarness.h"

#include "PresetDwellPlan.h"

#include <string>

using namespace RoonVis;

namespace
{

// Constants mirroring the two live paths so the window math tests read like the app.
constexpr double kWarmSettle = 2.0;    // kPresetPreloadPostTransitionSettleSeconds
constexpr double kWarmLead = 2.0;      // kPresetPreloadMinLeadSeconds
constexpr double kDirectSettle = 12.0; // kPresetDirectPreloadPostTransitionSettleSeconds
constexpr double kDirectLead = 5.0;    // kPresetDirectPreloadMinLeadSeconds

const std::string kNext = "next.milk";

void TestArmsWhenIntervalFits()
{
    // 30 s interval, instant cut (smoothWindow 0), warm-path windows: 30 - 2 = 28 >= 2 lead.
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/100.0, /*interval=*/30.0,
                                            /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    CHECK(plan.state == PresetDwellPlan::State::Armed);
    CHECK(plan.targetIndex == 5);
    CHECK(plan.targetPath == kNext);
    CHECK(plan.notBeforeTime == 102.0); // lastSwitch + settleWindow (100 + 0 + 2)
}

void TestSmoothWindowAddsToSettle()
{
    // Crossfade 1.5 s + settle 2 s = 3.5 s settle window; notBeforeTime shifts accordingly.
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/100.0, /*interval=*/30.0,
                                            /*smoothWindow=*/1.5, kWarmSettle, kWarmLead);
    CHECK(plan.state == PresetDwellPlan::State::Armed);
    CHECK(plan.notBeforeTime == 103.5);
}

void TestExhaustedWhenIntervalTooShort()
{
    // Direct-preload path: settle 12 + lead 5 = 17 required; a 15 s interval can't fit it.
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/100.0, /*interval=*/15.0,
                                            /*smoothWindow=*/0.0, kDirectSettle, kDirectLead);
    CHECK(plan.state == PresetDwellPlan::State::Exhausted);
    CHECK(plan.targetIndex == SIZE_MAX);
    CHECK(plan.targetPath.empty());
}

void TestLeadBoundaryExactFitArms()
{
    // interval - settleWindow == minLead exactly: legacy check is `< minLead` -> arms.
    // 19 - (12 + 2)  wait: use direct constants. settleWindow = 12, need lead 5 -> 17.
    // interval 17 exactly: 17 - 12 = 5 == lead -> arms (not strictly less than).
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/50.0, /*interval=*/17.0,
                                            /*smoothWindow=*/0.0, kDirectSettle, kDirectLead);
    CHECK(plan.state == PresetDwellPlan::State::Armed);

    // One epsilon shorter: 16.999 - 12 = 4.999 < 5 -> exhausted.
    PresetDwellPlan tooShort = ComputeDwellPlan(5, kNext, /*lastSwitch=*/50.0, /*interval=*/16.999,
                                                /*smoothWindow=*/0.0, kDirectSettle, kDirectLead);
    CHECK(tooShort.state == PresetDwellPlan::State::Exhausted);
}

void TestHoldExhausts()
{
    // nextIndex == SIZE_MAX (rotation returned HOLD / nothing eligible) -> Exhausted.
    PresetDwellPlan plan = ComputeDwellPlan(SIZE_MAX, "", /*lastSwitch=*/100.0, /*interval=*/30.0,
                                            /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    CHECK(plan.state == PresetDwellPlan::State::Exhausted);
}

void TestNoSwitchYetExhausts()
{
    // lastSwitchTime <= 0: no confirmed switch has established a switch time. The legacy
    // canWarmPresetAtTime returned NO in this case; the plan stays Exhausted until the
    // first confirm's recompute supplies a real lastSwitchTime.
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/0.0, /*interval=*/30.0,
                                            /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    CHECK(plan.state == PresetDwellPlan::State::Exhausted);

    PresetDwellPlan negative = ComputeDwellPlan(5, kNext, /*lastSwitch=*/-1.0, /*interval=*/30.0,
                                                /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    CHECK(negative.state == PresetDwellPlan::State::Exhausted);
}

void TestReadyIsOneTimeComparison()
{
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/100.0, /*interval=*/30.0,
                                            /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    CHECK(plan.notBeforeTime == 102.0);

    CHECK(!DwellPlanReady(plan, 101.9)); // before the window
    CHECK(DwellPlanReady(plan, 102.0));  // exactly at the window (>=)
    CHECK(DwellPlanReady(plan, 500.0));  // and forever after, until a recompute replaces it
}

void TestNonArmedStatesAreNeverReady()
{
    PresetDwellPlan idle;
    CHECK(idle.state == PresetDwellPlan::State::Idle);
    CHECK(!DwellPlanReady(idle, 1e9));

    PresetDwellPlan satisfied;
    satisfied.state = PresetDwellPlan::State::Satisfied;
    satisfied.notBeforeTime = 0.0; // even with an ancient notBeforeTime, Satisfied != ready
    CHECK(!DwellPlanReady(satisfied, 1e9));

    PresetDwellPlan exhausted;
    exhausted.state = PresetDwellPlan::State::Exhausted;
    CHECK(!DwellPlanReady(exhausted, 1e9));
}

// The exhausted-semantics case the plan review demanded: a FAILED warm sets the plan to
// Exhausted, and an Exhausted plan is never ready — so the render path does NOT retry the
// same target for the rest of the dwell, only a recompute event (a new confirm / listsChanged
// / modeChanged / etc.) replaces the plan and lets warming resume.
//
// Equivalence to the legacy depth-1 attempt-filter: on a failed warm, the old path set
// _preloadAttemptPresetIndex/_preloadAttemptPresetPath to the (confirmed, candidate) pair;
// presetWarmCandidatesWithDepth:1 then SKIPPED that candidate on every subsequent frame.
// Because depth was 1, there was no alternative candidate to fall back to — so the net effect
// was exactly "never retry this candidate within this dwell." The Exhausted state reproduces
// that: once state==Exhausted, DwellPlanReady is false until the next recompute, which is the
// same set of events that formerly cleared the attempt filter (a confirm cleared it via the
// _preloadAttemptPreset* = SIZE_MAX/clear at the confirm sites; a settings/list change cleared
// it via invalidatePreloadedPresetTracking). No retry loop existed then; none exists now.
void TestExhaustedDoesNotRetryUntilRecompute()
{
    // Simulate the render path: compute a plan, it goes ready, the warm fails -> Exhausted.
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/100.0, /*interval=*/30.0,
                                            /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    CHECK(DwellPlanReady(plan, 200.0)); // would warm now

    // Warm attempt failed: the bridge sets state = Exhausted (models the on-failure path).
    plan.state = PresetDwellPlan::State::Exhausted;

    // For the rest of the dwell, no matter how much later, the plan never re-arms itself.
    CHECK(!DwellPlanReady(plan, 200.1));
    CHECK(!DwellPlanReady(plan, 1e6));

    // Only a recompute (a fresh ComputeDwellPlan) can produce an Armed plan again.
    PresetDwellPlan recomputed = ComputeDwellPlan(6, "other.milk", /*lastSwitch=*/300.0,
                                                  /*interval=*/30.0, /*smoothWindow=*/0.0,
                                                  kWarmSettle, kWarmLead);
    CHECK(recomputed.state == PresetDwellPlan::State::Armed);
    CHECK(recomputed.targetIndex == 6);
}

void TestSatisfiedAlsoDoesNotRetry()
{
    // A successful warm sets Satisfied; like Exhausted, it is never ready again this dwell.
    PresetDwellPlan plan = ComputeDwellPlan(5, kNext, /*lastSwitch=*/100.0, /*interval=*/30.0,
                                            /*smoothWindow=*/0.0, kWarmSettle, kWarmLead);
    plan.state = PresetDwellPlan::State::Satisfied; // warm succeeded
    CHECK(!DwellPlanReady(plan, 1e6));
}

}  // namespace

void RunPresetDwellPlanTests()
{
    TestArmsWhenIntervalFits();
    TestSmoothWindowAddsToSettle();
    TestExhaustedWhenIntervalTooShort();
    TestLeadBoundaryExactFitArms();
    TestHoldExhausts();
    TestNoSwitchYetExhausts();
    TestReadyIsOneTimeComparison();
    TestNonArmedStatesAreNeverReady();
    TestExhaustedDoesNotRetryUntilRecompute();
    TestSatisfiedAlsoDoesNotRetry();
}
