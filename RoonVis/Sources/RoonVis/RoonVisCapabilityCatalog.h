#pragma once

#import <Foundation/Foundation.h>

#include "PresetCapabilityManifest.h"

#include <string>
#include <unordered_set>
#include <vector>

// W2b bridge adapter: loads the bundled HDCapabilityManifest.json once at init
// and evaluates every record through the pure eligibility policy
// (PresetEligibilityPolicy), so ProjectMBridge's HD-tier catalog construction
// consumes plain name sets instead of re-deriving policy inline.
//
// FAIL-CLOSED contract: RoonVisLoadHDCapabilityCatalog returns YES only when
// the manifest parsed Valid against this tier's expected profile. Every other
// status (Missing / Malformed / ProfileMismatch) leaves the sets empty and the
// bridge falls back to the legacy HDVerifiedPresets.json allowlist — never to
// an unrestricted catalog.
struct RoonVisCapabilityCatalog
{
    RoonVis::ManifestLoadStatus status = RoonVis::ManifestLoadStatus::Missing;

    // Filenames of records with safety == safe: the browse-visible catalog net
    // (all steadyState verdicts included — manual pick stays allowed per D1/D2).
    // Presets absent from the manifest are NOT in this set, so the pre-manifest
    // rule for never-screened presets (absent = not included) is preserved.
    std::unordered_set<std::string> visibleNames;

    // Filenames of ALL records (any safety). A manifest record supersedes the
    // legacy known-slow / static-heavy verdicts for that filename (manifest
    // evidence wins); the known-crash static list stays a hard block regardless.
    std::unordered_set<std::string> recordNames;

    // visibleInBrowse && !eligibleForRotation — the manual-only/warmup set fed
    // to RotationEngine::SetTemporarilyUnavailable (query-time filter only).
    std::unordered_set<std::string> temporarilyUnavailable;

    // Pack-relative paths of the browse-visible records, in manifest order.
    // Drives the catalog fast path (mirrors the HDVerifiedPresets "paths"
    // mirror: a handful of stats instead of the ~6.6 s A8 full tree walk).
    std::vector<std::string> visibleRelativePaths;

    size_t recordCount = 0;
    size_t rotationEligibleCount = 0;
    size_t safetyExcludedCount = 0;
    // File read + parse + policy evaluation, milliseconds (init-only cost).
    double loadMillis = 0.0;
};

// Loads Resources/HDCapabilityManifest.json and evaluates it for the HD tier.
// Returns YES (and populates the sets) only when status == Valid; on any other
// status only `status` is meaningful. Init-time only — reads the bundle and
// allocates; never call on the per-frame path.
BOOL RoonVisLoadHDCapabilityCatalog(RoonVisCapabilityCatalog &outCatalog);

// Stable lowercase label for logging ("valid" / "missing" / "malformed" /
// "profile-mismatch").
const char *RoonVisManifestLoadStatusLabel(RoonVis::ManifestLoadStatus status);
