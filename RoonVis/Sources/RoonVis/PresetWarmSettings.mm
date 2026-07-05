#import "PresetWarmSettings.h"

#import "RoonVisCrashReporter.h"

BOOL RoonVisPresetWarmCacheEnabledSetting()
{
    NSString *envValue = NSProcessInfo.processInfo.environment[@"ROONVIS_PRESET_WARM_CACHE"];
    if (envValue.length > 0)
    {
        return envValue.boolValue;
    }
    // Default ON (device-validated 2026-07-04: 45-min burn-in, steady 50fps, no leak, init
    // spike avg 651->133ms). Env ROONVIS_PRESET_WARM_CACHE / this default still override.
    NSNumber *defaultsValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"RoonVisPresetWarmCacheEnabled"];
    return defaultsValue != nil ? defaultsValue.boolValue : YES;
}

RoonVis::PresetWarmStrategy RoonVisPresetWarmStrategySetting()
{
    NSString *strategy = NSProcessInfo.processInfo.environment[@"ROONVIS_PRESET_WARM_STRATEGY"];
    if (strategy.length == 0)
    {
        strategy = [[NSUserDefaults standardUserDefaults] stringForKey:@"RoonVisPresetWarmStrategy"];
    }
    if (strategy.length == 0)
    {
        return RoonVis::PresetWarmStrategy::IdleFrame;
    }

    NSString *normalized = strategy.lowercaseString;
    if ([normalized isEqualToString:@"shared-context"] || [normalized isEqualToString:@"shared_context"])
    {
        RoonVisLog(@"Preset warm cache: shared-context strategy is disabled; using idle-frame main-context");
        return RoonVis::PresetWarmStrategy::IdleFrame;
    }
    if (![normalized isEqualToString:@"idle-frame"] && ![normalized isEqualToString:@"idle_frame"])
    {
        RoonVisLog(@"Preset warm cache: unknown strategy %@; using idle-frame", strategy);
    }
    return RoonVis::PresetWarmStrategy::IdleFrame;
}
