#include "TestHarness.h"

#include "PresetEligibilityPolicy.h"

#include <cstring>

using namespace RoonVis;

namespace
{

bool ReasonIs(const PresetEligibility &result, const char *expected)
{
    return result.reason != nullptr && std::strcmp(result.reason, expected) == 0;
}

bool Flags(const PresetEligibility &result, bool browse, bool rotation, bool warmer)
{
    return result.visibleInBrowse == browse && result.eligibleForRotation == rotation &&
           result.eligibleForWarmer == warmer;
}

CapabilityRecord MakeRecord(PresetSafety safety,
                            SteadyStateVerdict steadyState,
                            ActivationMechanism mechanism,
                            ActivationVerdict verdict)
{
    CapabilityRecord record;
    record.name = "x.milk";
    record.path = "Cat/x.milk";
    record.safety = safety;
    record.steadyState = steadyState;
    record.activationMechanism = mechanism;
    record.activationVerdict = verdict;
    return record;
}

RuntimeReadiness AllReady()
{
    RuntimeReadiness readiness;
    readiness.tier1Enabled = true;
    readiness.tier1SeedLoaded = true;
    readiness.tier1FingerprintMatches = true;
    readiness.tier1EntryPresent = true;
    readiness.blobDurable = true;
    return readiness;
}

RuntimeReadiness NothingReady()
{
    return RuntimeReadiness();
}

// (1) safety != safe -> invisible everywhere, regardless of every other input
//     (readiness can never resurrect an unsafe preset).
void TestHardSafetyBlock()
{
    const PresetSafety unsafeValues[] = {PresetSafety::KnownCrash, PresetSafety::Unsupported};
    const SteadyStateVerdict steadyValues[] = {
        SteadyStateVerdict::Unknown, SteadyStateVerdict::Pass,
        SteadyStateVerdict::Marginal, SteadyStateVerdict::Fail};
    const ActivationMechanism mechanisms[] = {
        ActivationMechanism::None, ActivationMechanism::Tier1Cache,
        ActivationMechanism::ProgramBlob};
    const ActivationVerdict verdicts[] = {
        ActivationVerdict::Unknown, ActivationVerdict::Sufficient,
        ActivationVerdict::Insufficient, ActivationVerdict::Unresolved};
    for (PresetSafety safety : unsafeValues)
    {
        for (SteadyStateVerdict steady : steadyValues)
        {
            for (ActivationMechanism mechanism : mechanisms)
            {
                for (ActivationVerdict verdict : verdicts)
                {
                    PresetEligibility result = EvaluatePresetEligibility(
                        MakeRecord(safety, steady, mechanism, verdict), AllReady());
                    CHECK(Flags(result, false, false, false));
                    CHECK(ReasonIs(result, "hard-safety-block"));
                }
            }
        }
    }
}

// (2) steadyState fail -> browsable, manual-only (no rotation, no warmer) —
//     even a sufficient+ready mechanism can't override a proven fail.
void TestSteadyStateFail()
{
    const ActivationMechanism mechanisms[] = {
        ActivationMechanism::None, ActivationMechanism::Tier1Cache,
        ActivationMechanism::ProgramBlob};
    const ActivationVerdict verdicts[] = {
        ActivationVerdict::Unknown, ActivationVerdict::Sufficient,
        ActivationVerdict::Insufficient, ActivationVerdict::Unresolved};
    for (ActivationMechanism mechanism : mechanisms)
    {
        for (ActivationVerdict verdict : verdicts)
        {
            PresetEligibility result = EvaluatePresetEligibility(
                MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Fail, mechanism, verdict),
                AllReady());
            CHECK(Flags(result, true, false, false));
            CHECK(ReasonIs(result, "steady-state-fail"));
        }
    }
}

// (3) steadyState unknown | marginal -> browsable + warmable, not rotated —
//     for every mechanism/verdict/readiness combination.
void TestSteadyStateUnproven()
{
    const SteadyStateVerdict unproven[] = {SteadyStateVerdict::Unknown,
                                           SteadyStateVerdict::Marginal};
    const ActivationMechanism mechanisms[] = {
        ActivationMechanism::None, ActivationMechanism::Tier1Cache,
        ActivationMechanism::ProgramBlob};
    const ActivationVerdict verdicts[] = {
        ActivationVerdict::Unknown, ActivationVerdict::Sufficient,
        ActivationVerdict::Insufficient, ActivationVerdict::Unresolved};
    const RuntimeReadiness readinessValues[] = {AllReady(), NothingReady()};
    for (SteadyStateVerdict steady : unproven)
    {
        for (ActivationMechanism mechanism : mechanisms)
        {
            for (ActivationVerdict verdict : verdicts)
            {
                for (const RuntimeReadiness &readiness : readinessValues)
                {
                    PresetEligibility result = EvaluatePresetEligibility(
                        MakeRecord(PresetSafety::Safe, steady, mechanism, verdict), readiness);
                    CHECK(Flags(result, true, false, true));
                    CHECK(ReasonIs(result, "requires-validation"));
                }
            }
        }
    }
}

// (4) pass + verdict != sufficient -> activation-unproven: rotation false, and
//     warmable only when there is a mechanism to prove (mechanism != none).
void TestActivationUnproven()
{
    const ActivationVerdict notSufficient[] = {
        ActivationVerdict::Unknown, ActivationVerdict::Insufficient,
        ActivationVerdict::Unresolved};
    const RuntimeReadiness readinessValues[] = {AllReady(), NothingReady()};
    for (ActivationVerdict verdict : notSufficient)
    {
        for (const RuntimeReadiness &readiness : readinessValues)
        {
            // mechanism none: nothing to warm.
            PresetEligibility none = EvaluatePresetEligibility(
                MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Pass,
                           ActivationMechanism::None, verdict),
                readiness);
            CHECK(Flags(none, true, false, false));
            CHECK(ReasonIs(none, "activation-unproven"));

            // mechanism tier1-cache / program-blob: warmable.
            PresetEligibility tier1 = EvaluatePresetEligibility(
                MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Pass,
                           ActivationMechanism::Tier1Cache, verdict),
                readiness);
            CHECK(Flags(tier1, true, false, true));
            CHECK(ReasonIs(tier1, "activation-unproven"));

            PresetEligibility blob = EvaluatePresetEligibility(
                MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Pass,
                           ActivationMechanism::ProgramBlob, verdict),
                readiness);
            CHECK(Flags(blob, true, false, true));
            CHECK(ReasonIs(blob, "activation-unproven"));
        }
    }
}

// (5) pass + sufficient + mechanism none -> always rotation-eligible, readiness
//     irrelevant (there is no prerequisite).
void TestMechanismNoneAlwaysReady()
{
    const RuntimeReadiness readinessValues[] = {AllReady(), NothingReady()};
    for (const RuntimeReadiness &readiness : readinessValues)
    {
        PresetEligibility result = EvaluatePresetEligibility(
            MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Pass,
                       ActivationMechanism::None, ActivationVerdict::Sufficient),
            readiness);
        CHECK(Flags(result, true, true, true));
        CHECK(ReasonIs(result, "eligible"));
    }
}

// (6) pass + sufficient + tier1-cache: rotation needs ALL FOUR tier1 flags; any
//     single missing flag demotes to requires-warmup (tier1-disabled,
//     seed-failed, fingerprint-stale, entry-missing).
void TestTier1MechanismReadiness()
{
    const CapabilityRecord record =
        MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Pass,
                   ActivationMechanism::Tier1Cache, ActivationVerdict::Sufficient);

    // All four flags set -> eligible; blobDurable is irrelevant to tier1.
    RuntimeReadiness ready = AllReady();
    ready.blobDurable = false;
    PresetEligibility admitted = EvaluatePresetEligibility(record, ready);
    CHECK(Flags(admitted, true, true, true));
    CHECK(ReasonIs(admitted, "eligible"));

    // Each flag individually false -> requires-warmup.
    bool RuntimeReadiness::*tier1Flags[] = {
        &RuntimeReadiness::tier1Enabled,
        &RuntimeReadiness::tier1SeedLoaded,
        &RuntimeReadiness::tier1FingerprintMatches,
        &RuntimeReadiness::tier1EntryPresent,
    };
    for (bool RuntimeReadiness::*flag : tier1Flags)
    {
        RuntimeReadiness demoted = AllReady();
        demoted.*flag = false;
        PresetEligibility result = EvaluatePresetEligibility(record, demoted);
        CHECK(Flags(result, true, false, true));
        CHECK(ReasonIs(result, "requires-warmup"));
    }

    // All tier1 flags down together.
    PresetEligibility down = EvaluatePresetEligibility(record, NothingReady());
    CHECK(Flags(down, true, false, true));
    CHECK(ReasonIs(down, "requires-warmup"));
}

// (7) pass + sufficient + program-blob: gated solely on blobDurable (the tier1
//     flags are irrelevant either way).
void TestProgramBlobMechanismReadiness()
{
    const CapabilityRecord record =
        MakeRecord(PresetSafety::Safe, SteadyStateVerdict::Pass,
                   ActivationMechanism::ProgramBlob, ActivationVerdict::Sufficient);

    // Durable blob with every tier1 flag down -> admitted.
    RuntimeReadiness blobOnly = NothingReady();
    blobOnly.blobDurable = true;
    PresetEligibility admitted = EvaluatePresetEligibility(record, blobOnly);
    CHECK(Flags(admitted, true, true, true));
    CHECK(ReasonIs(admitted, "eligible"));

    // No durable blob with every tier1 flag up -> requires-warmup.
    RuntimeReadiness tier1Only = AllReady();
    tier1Only.blobDurable = false;
    PresetEligibility demoted = EvaluatePresetEligibility(record, tier1Only);
    CHECK(Flags(demoted, true, false, true));
    CHECK(ReasonIs(demoted, "requires-warmup"));
}

} // namespace

void RunPresetEligibilityPolicyTests()
{
    TestHardSafetyBlock();
    TestSteadyStateFail();
    TestSteadyStateUnproven();
    TestActivationUnproven();
    TestMechanismNoneAlwaysReady();
    TestTier1MechanismReadiness();
    TestProgramBlobMechanismReadiness();
}
