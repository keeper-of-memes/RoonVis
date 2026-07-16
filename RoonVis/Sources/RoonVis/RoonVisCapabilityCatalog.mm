#import "RoonVisCapabilityCatalog.h"

#include "PresetEligibilityPolicy.h"

#import <QuartzCore/QuartzCore.h>

const char *RoonVisManifestLoadStatusLabel(RoonVis::ManifestLoadStatus status)
{
    switch (status)
    {
        case RoonVis::ManifestLoadStatus::Valid:
            return "valid";
        case RoonVis::ManifestLoadStatus::Missing:
            return "missing";
        case RoonVis::ManifestLoadStatus::Malformed:
            return "malformed";
        case RoonVis::ManifestLoadStatus::ProfileMismatch:
            return "profile-mismatch";
    }
    return "unknown";
}

BOOL RoonVisLoadHDCapabilityCatalog(RoonVisCapabilityCatalog &outCatalog)
{
    outCatalog = RoonVisCapabilityCatalog();

#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    // Diagnostic hook: pretend the manifest is absent so the legacy verified-
    // allowlist fallback can be exercised without file surgery on an installed
    // bundle. Compiled out of Release like the other ROONVIS_ env hooks.
    if (NSProcessInfo.processInfo.environment[@"ROONVIS_IGNORE_CAPABILITY_MANIFEST"].boolValue)
    {
        outCatalog.status = RoonVis::ManifestLoadStatus::Missing;
        return NO;
    }
#endif

    const CFTimeInterval loadStart = CACurrentMediaTime();
    NSString *manifestPath = [[NSBundle mainBundle] pathForResource:@"HDCapabilityManifest"
                                                             ofType:@"json"];
    NSData *manifestData = manifestPath != nil ? [NSData dataWithContentsOfFile:manifestPath] : nil;
    if (manifestData.length == 0)
    {
        outCatalog.status = RoonVis::ManifestLoadStatus::Missing;
        return NO;
    }

    // Expected measurement profile for this tier. fps 30 is the manifest's
    // recorded campaign budget basis — a TIER constant (DefaultFrameRateForTier
    // for HD), NOT the live panel rate: the panel varies 25/30 Hz by TV mode,
    // the campaign evidence was judged against the recorded 30 fps budget, and
    // runtime fps differences are informational only. All other fields are left
    // empty/zero so ParseCapabilityManifest skips them (deviceTier + fps are
    // always compared; the rest only when non-empty/non-zero in `expected`).
    RoonVis::CapabilityProfile expected;
    expected.deviceTier = "A8";
    expected.fps = 30;

    std::string jsonText(static_cast<const char *>(manifestData.bytes), manifestData.length);
    RoonVis::CapabilityManifest manifest;
    outCatalog.status = RoonVis::ParseCapabilityManifest(jsonText, expected, manifest);
    if (outCatalog.status != RoonVis::ManifestLoadStatus::Valid)
    {
        return NO;
    }

    // TODO(W5): runtime readiness is hardwired ALL-FALSE until the Tier-1
    // transpile-cache wiring lands (W5 integration provides real probes). Under
    // the policy this yields rotation-eligible ONLY for {mechanism none,
    // verdict sufficient} records — the 594 device-verified presets — and
    // requires-warmup/validation for the rest: the SAFE initial posture. The
    // 779 recovered presets become rotation-eligible when W7a flips their
    // verdicts and W5 supplies readiness.
    const RoonVis::RuntimeReadiness readiness;

    outCatalog.recordCount = manifest.presets.size();
    outCatalog.visibleNames.reserve(manifest.presets.size());
    outCatalog.recordNames.reserve(manifest.presets.size());
    outCatalog.visibleRelativePaths.reserve(manifest.presets.size());
    for (const RoonVis::CapabilityRecord &record : manifest.presets)
    {
        outCatalog.recordNames.insert(record.name);
        const RoonVis::PresetEligibility eligibility =
            RoonVis::EvaluatePresetEligibility(record, readiness);
        if (!eligibility.visibleInBrowse)
        {
            // safety != safe (hard-safety-block): excluded from the catalog
            // entirely by the bridge's visibleNames net.
            outCatalog.safetyExcludedCount++;
            continue;
        }
        outCatalog.visibleNames.insert(record.name);
        outCatalog.visibleRelativePaths.push_back(record.path);
        if (eligibility.eligibleForRotation)
        {
            outCatalog.rotationEligibleCount++;
        }
        else
        {
            outCatalog.temporarilyUnavailable.insert(record.name);
        }
    }
    outCatalog.loadMillis = (CACurrentMediaTime() - loadStart) * 1000.0;
    return YES;
}
