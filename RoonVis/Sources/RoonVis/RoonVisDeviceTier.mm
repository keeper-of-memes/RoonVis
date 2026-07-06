#import "RoonVisDeviceTier.h"

#include "DeviceTier.h"

#include <TargetConditionals.h>

#include <string>
#include <sys/sysctl.h>

static std::string RoonVisMachineModelString(void)
{
#if ROONVIS_ENABLE_DIAGNOSTIC_MODES
    // Diagnostic override for exercising other tiers (e.g. the HD path on the
    // simulator, whose injected SIMULATOR_MODEL_IDENTIFIER can't be replaced).
    const char *overrideModel = getenv("ROONVIS_MACHINE_MODEL");
    if (overrideModel != nullptr && overrideModel[0] != '\0')
    {
        return std::string(overrideModel);
    }
#endif
#if TARGET_OS_SIMULATOR
    // The simulator's hw.machine reports the Mac; the simulated device model
    // is carried in the environment.
    const char *simModel = getenv("SIMULATOR_MODEL_IDENTIFIER");
    if (simModel != nullptr && simModel[0] != '\0')
    {
        return std::string(simModel);
    }
#endif
    char machine[64] = {0};
    size_t size = sizeof(machine) - 1;
    if (sysctlbyname("hw.machine", machine, &size, nullptr, 0) != 0)
    {
        return std::string();
    }
    return std::string(machine);
}

RoonVisDeviceTierValue RoonVisCurrentDeviceTier(void)
{
    static RoonVisDeviceTierValue tier = [] {
        const std::string machine = RoonVisMachineModelString();
        const RoonVis::DeviceTier parsed = RoonVis::ParseAppleTVModelTier(machine);
        RoonVisDeviceTierValue value = RoonVisDeviceTier4KGen3OrLater;
        switch (parsed)
        {
            case RoonVis::DeviceTier::HD:
                value = RoonVisDeviceTierHD;
                break;
            case RoonVis::DeviceTier::FourKGen1:
                value = RoonVisDeviceTier4KGen1;
                break;
            case RoonVis::DeviceTier::FourKGen2:
                value = RoonVisDeviceTier4KGen2;
                break;
            case RoonVis::DeviceTier::FourKGen3OrLater:
                value = RoonVisDeviceTier4KGen3OrLater;
                break;
        }
        NSLog(@"RoonVis device tier: machine=%s tier=%ld", machine.c_str(), static_cast<long>(value));
        return value;
    }();
    return tier;
}

static RoonVis::DeviceTier RoonVisCurrentCppTier(void)
{
    switch (RoonVisCurrentDeviceTier())
    {
        case RoonVisDeviceTierHD:
            return RoonVis::DeviceTier::HD;
        case RoonVisDeviceTier4KGen1:
            return RoonVis::DeviceTier::FourKGen1;
        case RoonVisDeviceTier4KGen2:
            return RoonVis::DeviceTier::FourKGen2;
        case RoonVisDeviceTier4KGen3OrLater:
            return RoonVis::DeviceTier::FourKGen3OrLater;
    }
    return RoonVis::DeviceTier::FourKGen3OrLater;
}

RoonVisDrawableSizePreset RoonVisMaxDrawablePresetForCurrentTier(void)
{
    return static_cast<RoonVisDrawableSizePreset>(RoonVis::MaxDrawablePresetForTier(RoonVisCurrentCppTier()));
}

RoonVisDrawableSizePreset RoonVisDefaultDrawablePresetForCurrentTier(void)
{
    return static_cast<RoonVisDrawableSizePreset>(RoonVis::DefaultDrawablePresetForTier(RoonVisCurrentCppTier()));
}

NSInteger RoonVisDefaultFrameRateForCurrentTier(void)
{
    return RoonVis::DefaultFrameRateForTier(RoonVisCurrentCppTier());
}

NSInteger RoonVisDefaultWarpMeshWidthForCurrentTier(void)
{
    return RoonVis::DefaultWarpMeshWidthForTier(RoonVisCurrentCppTier());
}

CGSize RoonVisDrawableSizeForPreset(RoonVisDrawableSizePreset preset)
{
    switch (preset)
    {
        case RoonVisDrawableSizePreset720p:
            return CGSizeMake(1280.0, 720.0);
        case RoonVisDrawableSizePreset1080p:
            return CGSizeMake(1920.0, 1080.0);
        case RoonVisDrawableSizePreset1440p:
            return CGSizeMake(2560.0, 1440.0);
        case RoonVisDrawableSizePreset4K:
            return CGSizeMake(3840.0, 2160.0);
    }
    return CGSizeMake(1920.0, 1080.0);
}

NSString *RoonVisDrawableSizePresetLabel(RoonVisDrawableSizePreset preset)
{
    switch (preset)
    {
        case RoonVisDrawableSizePreset720p:
            return @"720p";
        case RoonVisDrawableSizePreset1080p:
            return @"1080p";
        case RoonVisDrawableSizePreset1440p:
            return @"1440p";
        case RoonVisDrawableSizePreset4K:
            return @"4K";
    }
    return @"1080p";
}
