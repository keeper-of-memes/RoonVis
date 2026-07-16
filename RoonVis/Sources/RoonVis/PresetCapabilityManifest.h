#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace RoonVis
{

// W2b: decode/validate of the per-device preset capability manifest JSON.
// Pure C++17, no Foundation — the ObjC bridge reads the file bytes and passes
// them here (mirroring the PresetBlocklist / LegacyNameMigration pattern of
// hand-rolled, dependency-free JSON parsing).
//
// Fail-closed contract: any parse error, schema violation, or UNKNOWN enum
// string yields Malformed (never a partially-filled manifest). Extra JSON
// fields are ignored (forward compatibility). `Missing` is decided by the
// CALLER (file absent) — ParseCapabilityManifest never returns it.

enum class ManifestLoadStatus
{
    Valid,
    Missing,        // caller-decided: manifest file absent
    Malformed,      // JSON parse failure, schema violation, or unknown enum
    ProfileMismatch // parsed fine, but written for a different device profile
};

enum class PresetSafety
{
    Safe,
    KnownCrash,  // "known-crash"
    Unsupported, // "unsupported"
};

enum class SteadyStateVerdict
{
    Unknown,
    Pass,
    Marginal,
    Fail,
};

enum class ActivationMechanism
{
    None,        // "none": activates cleanly with no cache prerequisite
    Tier1Cache,  // "tier1-cache": needs the tier-1 transpile cache entry
    ProgramBlob, // "program-blob": needs a durable ANGLE program blob
};

enum class ActivationVerdict
{
    Unknown,
    Sufficient,
    Insufficient,
    Unresolved,
};

// The device/build profile a manifest was measured under. Doubles as the
// EXPECTED profile the caller passes in for validation.
struct CapabilityProfile
{
    std::string deviceTier;
    std::string drawable;
    int fps = 0;
    std::string projectMRevision;
    std::string angleRevision;
    int rvppVersion = 0;
    std::string transpileSalts;
    std::string tier1CacheFingerprint;
};

// Measured steady-state evidence backing a record's verdicts.
struct CapabilityEvidence
{
    double settledP50Ms = 0.0;
    double settledP95Ms = 0.0;
    double settledP99Ms = 0.0;
    double overBudgetRate = 0.0;
    int64_t sampleCount = 0;
};

// One preset's capability record.
struct CapabilityRecord
{
    std::string name; // display name (lastPathComponent), the engine key
    std::string path; // pack-relative path
    PresetSafety safety = PresetSafety::Unsupported;
    SteadyStateVerdict steadyState = SteadyStateVerdict::Unknown;
    ActivationMechanism activationMechanism = ActivationMechanism::None;
    ActivationVerdict activationVerdict = ActivationVerdict::Unknown;
    CapabilityEvidence evidence;
};

struct CapabilityManifest
{
    int schema = 0;
    CapabilityProfile profile;
    std::vector<CapabilityRecord> presets;
};

// Parses `jsonText` into `out` and validates it against `expected`.
//
// Returns:
// - Malformed when the JSON does not parse, `schema` != 1, a required field is
//   missing or mistyped, or ANY enum string is unknown (fail closed). `out` is
//   reset to a default-constructed manifest in this case.
// - ProfileMismatch when the manifest parsed cleanly but was measured under a
//   different profile. Exact match rules vs `expected`:
//     * deviceTier and fps ALWAYS compared (exact match required);
//     * drawable, projectMRevision, angleRevision, transpileSalts and
//       tier1CacheFingerprint compared only when non-empty in `expected`;
//     * rvppVersion compared only when non-zero in `expected`.
//   `out` retains the parsed manifest so the caller can log what it found.
// - Valid otherwise, with `out` fully populated.
//
// Never returns Missing (the caller maps "file absent" to Missing itself).
ManifestLoadStatus ParseCapabilityManifest(const std::string &jsonText,
                                           const CapabilityProfile &expected,
                                           CapabilityManifest &out);

} // namespace RoonVis
