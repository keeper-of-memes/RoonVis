#include "PresetEligibilityPolicy.h"

namespace RoonVis
{
namespace
{

bool MechanismReady(ActivationMechanism mechanism, const RuntimeReadiness &readiness)
{
    switch (mechanism)
    {
        case ActivationMechanism::None:
            return true;
        case ActivationMechanism::Tier1Cache:
            return readiness.tier1Enabled && readiness.tier1SeedLoaded &&
                   readiness.tier1FingerprintMatches && readiness.tier1EntryPresent;
        case ActivationMechanism::ProgramBlob:
            return readiness.blobDurable;
    }
    return false; // unreachable; fail closed on a corrupted enum value
}

} // namespace

PresetEligibility EvaluatePresetEligibility(const CapabilityRecord &record,
                                            const RuntimeReadiness &readiness)
{
    // 1. Hard safety block: invisible everywhere (the bridge excludes it from
    //    the catalog entirely; this is the policy's belt-and-braces answer).
    if (record.safety != PresetSafety::Safe)
    {
        return {false, false, false, "hard-safety-block"};
    }

    // 2. Proven steady-state fail: browsable (manual selection allowed, the
    //    learned-slow UX), never rotated, never warmed.
    if (record.steadyState == SteadyStateVerdict::Fail)
    {
        return {true, false, false, "steady-state-fail"};
    }

    // 3. Unproven steady state: browsable + warmable (warming IS the
    //    validation path), not rotated until proven.
    if (record.steadyState != SteadyStateVerdict::Pass)
    {
        return {true, false, true, "requires-validation"};
    }

    // 4. steadyState == pass. Rotation additionally needs a PROVEN-sufficient
    //    activation mechanism that is ready right now.
    if (record.activationVerdict != ActivationVerdict::Sufficient)
    {
        // Warmer only helps when there is a mechanism to warm/prove.
        const bool warmable = record.activationMechanism != ActivationMechanism::None;
        return {true, false, warmable, "activation-unproven"};
    }

    if (!MechanismReady(record.activationMechanism, readiness))
    {
        return {true, false, true, "requires-warmup"};
    }

    return {true, true, true, "eligible"};
}

} // namespace RoonVis
