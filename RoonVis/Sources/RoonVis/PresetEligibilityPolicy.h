#pragma once

#include "PresetCapabilityManifest.h"

namespace RoonVis
{

// W2b: pure eligibility policy over (capability record x runtime readiness).
// No I/O, no state — the bridge evaluates this per preset after loading the
// manifest and probing the runtime caches, then feeds the results into the
// catalog (visibility), RotationEngine::SetTemporarilyUnavailable (rotation)
// and the warm scheduler (warmer).

// Snapshot of the runtime activation prerequisites, probed by the bridge.
struct RuntimeReadiness
{
    bool tier1Enabled = false;            // tier-1 transpile cache feature on
    bool tier1SeedLoaded = false;         // bundled seed loaded this session
    bool tier1FingerprintMatches = false; // seed fingerprint matches this build
    bool tier1EntryPresent = false;       // THIS preset's entry is in the cache
    bool blobDurable = false;             // durable ANGLE program blob on disk
};

// Policy output. `reason` is a static string (never owned, never freed) for
// logging/diagnostics; compare by content, not identity.
struct PresetEligibility
{
    bool visibleInBrowse = false;
    bool eligibleForRotation = false;
    bool eligibleForWarmer = false;
    const char *reason = "";
};

// Decision ladder (approved W2b plan, verbatim semantics):
// 1. safety != safe                 -> {false, false, false, "hard-safety-block"}
//    (catalog exclusion is the bridge's job; the policy just says invisible).
// 2. steadyState == fail            -> {true, false, false, "steady-state-fail"}
//    (manual-only, matching the learned-slow UX).
// 3. steadyState unknown | marginal -> {true, false, true, "requires-validation"}.
// 4. steadyState == pass:
//    a. activationVerdict != sufficient -> {true, false, mechanism != none,
//       "activation-unproven"} (rotation stays false until proven).
//    b. mechanism readiness: none -> always ready; tier1-cache -> all four
//       tier1 flags; program-blob -> blobDurable. Not ready ->
//       {true, false, true, "requires-warmup"}.
//    c. ready + sufficient -> {true, true, true, "eligible"}.
PresetEligibility EvaluatePresetEligibility(const CapabilityRecord &record,
                                            const RuntimeReadiness &readiness);

} // namespace RoonVis
