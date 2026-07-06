#pragma once

#include <string>

namespace RoonVis
{

// Apple TV hardware tiers, ordered by capability. Parsed from the sysctl
// hw.machine model identifier ("AppleTV<major>,<minor>"). Anything newer than
// the known models (or unparseable) is treated as the most capable tier so
// future hardware never gets accidentally throttled.
enum class DeviceTier
{
    HD,              // AppleTV5,x  (Apple TV HD, A8, 1080p output, 2 GB)
    FourKGen1,       // AppleTV6,x  (Apple TV 4K 1st gen, A10X)
    FourKGen2,       // AppleTV11,x (Apple TV 4K 2nd gen, A12)
    FourKGen3OrLater // AppleTV14,x+ (Apple TV 4K 3rd gen, A15) and unknown/future
};

// Render-target presets, ordered so that a tier cap is a simple <= comparison.
enum class DrawableSizePreset
{
    P720 = 0,
    P1080 = 1,
    P1440 = 2,
    P2160 = 3,
};

// Pure parser: "AppleTV5,3" -> HD, "AppleTV14,1" -> FourKGen3OrLater.
// Non-AppleTV or malformed strings map to FourKGen3OrLater (see enum note).
DeviceTier ParseAppleTVModelTier(const std::string &machineModel);

// Tier-derived policy values (pure functions of the tier, host-testable).
DrawableSizePreset MaxDrawablePresetForTier(DeviceTier tier);     // HD: P1080, others: P2160
DrawableSizePreset DefaultDrawablePresetForTier(DeviceTier tier); // HD: P720, others: P1080
int DefaultFrameRateForTier(DeviceTier tier);                     // HD: 30, others: 60
int DefaultWarpMeshWidthForTier(DeviceTier tier);                 // HD: 64, others: 96

// Snaps an arbitrary requested rate to the nearest allowed cap {25, 30, 50, 60}.
int SnapFrameRateCap(int requested);

} // namespace RoonVis
