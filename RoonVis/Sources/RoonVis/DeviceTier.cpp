#include "DeviceTier.h"

#include <cstdlib>

namespace RoonVis
{

DeviceTier ParseAppleTVModelTier(const std::string &machineModel)
{
    // Expect "AppleTV<major>,<minor>". Anything else (simulator strings that
    // weren't mapped, Macs, future formats) is treated as the top tier.
    static const std::string prefix = "AppleTV";
    if (machineModel.compare(0, prefix.size(), prefix) != 0)
    {
        return DeviceTier::FourKGen3OrLater;
    }

    const char *digits = machineModel.c_str() + prefix.size();
    char *end = nullptr;
    const long major = std::strtol(digits, &end, 10);
    if (end == digits || major <= 0)
    {
        return DeviceTier::FourKGen3OrLater;
    }

    if (major <= 5)
    {
        return DeviceTier::HD; // AppleTV5,3 (earlier majors never ran this app)
    }
    if (major <= 6)
    {
        return DeviceTier::FourKGen1; // AppleTV6,2
    }
    if (major <= 11)
    {
        return DeviceTier::FourKGen2; // AppleTV11,1
    }
    return DeviceTier::FourKGen3OrLater; // AppleTV14,1 and future
}

DrawableSizePreset MaxDrawablePresetForTier(DeviceTier tier)
{
    // The HD outputs 1080p max; rendering above that wastes GPU and risks
    // memory pressure on its 2 GB. All 4K generations may select up to 2160p
    // (with a "may reduce frame rate" warning in the UI).
    return tier == DeviceTier::HD ? DrawableSizePreset::P1080 : DrawableSizePreset::P2160;
}

DrawableSizePreset DefaultDrawablePresetForTier(DeviceTier tier)
{
    return tier == DeviceTier::HD ? DrawableSizePreset::P720 : DrawableSizePreset::P1080;
}

int DefaultFrameRateForTier(DeviceTier tier)
{
    return tier == DeviceTier::HD ? 30 : 60;
}

int DefaultWarpMeshWidthForTier(DeviceTier tier)
{
    // The warp mesh is evaluated per-vertex on the CPU every frame; 96 is
    // tuned for the A15. Apple TV HD burn-in data (2026-07-06): at 96 the A8 renders
    // easy presets in ~18-25 ms at 720p but heavy windows average ~53 ms, so
    // the HD default steps down to 64 (users can raise it).
    return tier == DeviceTier::HD ? 64 : 96;
}

int SnapFrameRateCap(int requested)
{
    static constexpr int kAllowed[] = {25, 30, 50, 60};
    int best = kAllowed[0];
    int bestDistance = requested > kAllowed[0] ? requested - kAllowed[0] : kAllowed[0] - requested;
    for (const int candidate : kAllowed)
    {
        const int distance = requested > candidate ? requested - candidate : candidate - requested;
        // Equidistant requests keep the lower candidate (e.g. 40 -> 30):
        // strictly-less never replaces an equally-close earlier entry.
        if (distance < bestDistance)
        {
            best = candidate;
            bestDistance = distance;
        }
    }
    return best;
}

} // namespace RoonVis
