#import "RoonVisSettings.h"

#import "RoonVisCrashReporter.h"

#include "DeviceTier.h"
#include "SnapPCM.h"

#include <string>

#include <algorithm>
#include <cmath>

NSNotificationName const RoonVisSettingsDidChangeNotification = @"RoonVisSettingsDidChange";

NSString *const RoonVisSettingsRotationIntervalSecondsKey = @"rotationIntervalSeconds";
NSString *const RoonVisSettingsPresetRotationModeKey = @"presetRotationMode";
NSString *const RoonVisSettingsTransitionStyleKey = @"transitionStyle";
NSString *const RoonVisSettingsCrossfadeDurationSecondsKey = @"crossfadeDurationSeconds";
NSString *const RoonVisSettingsBeatHardCutSensitivityKey = @"beatHardCutSensitivity";
NSString *const RoonVisSettingsAudioSensitivityKey = @"audioSensitivity";
NSString *const RoonVisSettingsAudioInputDelayMsKey = @"audioInputDelayMs";
NSString *const RoonVisSettingsWarpMeshWidthKey = @"warpMeshWidth";
NSString *const RoonVisSettingsFavoritesOnlyRotationKey = @"favoritesOnlyRotation";
NSString *const RoonVisSettingsDiagnosticsOverlayEnabledKey = @"diagnosticsOverlayEnabled";
NSString *const RoonVisSettingsFavoritePresetFilenamesKey = @"favoritePresetFilenames";
NSString *const RoonVisSettingsHiddenPresetFilenamesKey = @"hiddenPresetFilenames";
NSString *const RoonVisSettingsFrameRateCapKey = @"frameRateCap";
NSString *const RoonVisSettingsDrawableSizePresetKey = @"drawableSizePreset";
NSString *const RoonVisSettingsSnapcastServerHostKey = @"snapcastServerHost";

namespace
{
static NSString *const kTransitionStyleCrossfadeValue = @"crossfade";
static NSString *const kTransitionStyleInstantValue = @"instant";
static NSString *const kPresetRotationModeLoopValue = @"loop";
static NSString *const kPresetRotationModeShuffleValue = @"shuffle";
static NSString *const kPresetRotationModeFavoritesValue = @"favorites";
static NSString *const kDrawableSizePreset720pValue = @"720p";
static NSString *const kDrawableSizePreset1080pValue = @"1080p";
static NSString *const kDrawableSizePreset1440pValue = @"1440p";
static NSString *const kDrawableSizePreset4KValue = @"4k";

static NSString *DrawableSizePresetPersistedValue(RoonVisDrawableSizePreset preset)
{
    switch (preset)
    {
        case RoonVisDrawableSizePreset720p:
            return kDrawableSizePreset720pValue;
        case RoonVisDrawableSizePreset1080p:
            return kDrawableSizePreset1080pValue;
        case RoonVisDrawableSizePreset1440p:
            return kDrawableSizePreset1440pValue;
        case RoonVisDrawableSizePreset4K:
            return kDrawableSizePreset4KValue;
    }
    return kDrawableSizePreset1080pValue;
}

// Clamps to the current device tier's maximum (the HD tops out at 1080p); an
// out-of-range stored value (e.g. defaults migrated from a 4K box) downgrades
// rather than erroring.
static RoonVisDrawableSizePreset ClampDrawableSizePresetToTier(RoonVisDrawableSizePreset preset)
{
    const RoonVisDrawableSizePreset maxPreset = RoonVisMaxDrawablePresetForCurrentTier();
    return preset > maxPreset ? maxPreset : preset;
}

static constexpr NSInteger kRotationIntervalMinimum = 60;
static constexpr NSInteger kRotationIntervalMaximum = 900;
static constexpr NSInteger kRotationIntervalStep = 60;
static constexpr double kCrossfadeDurationMinimum = 1.0;
static constexpr double kCrossfadeDurationMaximum = 5.0;
static constexpr double kCrossfadeDurationStep = 0.5;
static constexpr double kBeatHardCutSensitivityMinimum = 0.0;
static constexpr double kBeatHardCutSensitivityMaximum = 1.0;
static constexpr double kBeatHardCutSensitivityStep = 0.05;
static constexpr double kAudioSensitivityMinimum = 0.5;
static constexpr double kAudioSensitivityMaximum = 3.0;
static constexpr double kAudioSensitivityStep = 0.5;
static constexpr NSInteger kAudioInputDelayMinimumMs = 0;
static constexpr NSInteger kAudioInputDelayMaximumMs = 500;
static constexpr NSInteger kAudioInputDelayStepMs = 5;
// Warp mesh grid width. 48x36 is Milkdrop's default; 128x96 (the ceiling) is the finest.
// Stepped by 16 in width (12 in height, keeping 4:3). Default 96x72 — a lowered middle
// ground that recovers framerate on per-vertex-heavy presets vs the old hard-coded 128x96.
static constexpr NSInteger kWarpMeshWidthMinimum = 48;
static constexpr NSInteger kWarpMeshWidthMaximum = 128;
static constexpr NSInteger kWarpMeshWidthStep = 16;

// The build-time default host from Info.plist; the setting starts here and a
// cleared/invalid entry reverts to it.
static NSString *InfoPlistSnapcastHost(void)
{
    NSString *host = NSBundle.mainBundle.infoDictionary[@"SnapcastServerHost"];
    return [host isKindOfClass:NSString.class] && host.length > 0 ? host : @"192.0.2.10";
}

static NSString *NormalizedHostOrEmpty(NSString *value)
{
    if (![value isKindOfClass:NSString.class])
    {
        return @"";
    }
    std::string normalized = RoonVis::NormalizeSnapcastHost(std::string(value.UTF8String ?: ""));
    return normalized.empty() ? @"" : [NSString stringWithUTF8String:normalized.c_str()];
}

static NSInteger ClampIntegerToStep(NSInteger value, NSInteger minimum, NSInteger maximum, NSInteger step)
{
    value = MAX(minimum, MIN(maximum, value));
    NSInteger offset = value - minimum;
    NSInteger snappedOffset = static_cast<NSInteger>(std::lround(static_cast<double>(offset) / static_cast<double>(step))) * step;
    return MAX(minimum, MIN(maximum, minimum + snappedOffset));
}

static double ClampDoubleToStep(double value, double minimum, double maximum, double step)
{
    if (!std::isfinite(value))
    {
        value = minimum;
    }
    value = std::max(minimum, std::min(maximum, value));
    double snapped = minimum + (std::round((value - minimum) / step) * step);
    return std::max(minimum, std::min(maximum, snapped));
}

static NSArray<NSString *> *SortedFilenameArrayFromSet(NSSet<NSString *> *filenames)
{
    NSMutableArray<NSString *> *validFilenames = [NSMutableArray arrayWithCapacity:filenames.count];
    for (NSString *filename in filenames)
    {
        if ([filename isKindOfClass:NSString.class] && filename.length > 0)
        {
            [validFilenames addObject:filename];
        }
    }
    return [validFilenames sortedArrayUsingSelector:@selector(compare:)];
}

static NSSet<NSString *> *FilenameSetFromDefaultsValue(id value)
{
    if (![value isKindOfClass:NSArray.class])
    {
        return [NSSet set];
    }

    NSMutableSet<NSString *> *filenames = [NSMutableSet set];
    for (id item in static_cast<NSArray *>(value))
    {
        if ([item isKindOfClass:NSString.class] && [item length] > 0)
        {
            [filenames addObject:item];
        }
    }
    return filenames;
}
}

@implementation RoonVisSettings

+ (void)load
{
    [self registerDefaults];
}

+ (instancetype)sharedSettings
{
    static RoonVisSettings *settings = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        settings = [[RoonVisSettings alloc] init];
    });
    return settings;
}

+ (void)registerDefaults
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *defaults = @{
            RoonVisSettingsRotationIntervalSecondsKey: @(60),
            RoonVisSettingsPresetRotationModeKey: kPresetRotationModeShuffleValue,
            // Default CROSSFADE. The historical "blend-crasher" ship-blocker was traced
            // to a bug in the per-transition diagnostic recording (now removed) that
            // SIGSEGV'd on ANY soft-cut regardless of preset — not the presets (see the
            // CORRECTION in ProjectMBridge kKnownCrashingPresetFilenames and
            // KNOWN_ISSUES.md). Confirmed on device (task 0.5, 2026-07-03): a 40-min
            // soft-cut soak on the ATV4K (A15 GPU, live audio) ran 30 crossfade
            // transitions with zero crashes. The only genuine crasher
            // (LuX_-_Heavy_Texture_Trip_1, a load-crasher at any cut) stays blocklisted.
            RoonVisSettingsTransitionStyleKey: kTransitionStyleCrossfadeValue,
            RoonVisSettingsCrossfadeDurationSecondsKey: @(3.0),
            RoonVisSettingsBeatHardCutSensitivityKey: @(1.0),
            RoonVisSettingsAudioSensitivityKey: @(1.0),
            RoonVisSettingsAudioInputDelayMsKey: @(270),
            RoonVisSettingsWarpMeshWidthKey: @(RoonVisDefaultWarpMeshWidthForCurrentTier()),
            RoonVisSettingsFavoritesOnlyRotationKey: @NO,
            RoonVisSettingsDiagnosticsOverlayEnabledKey: @NO,
            RoonVisSettingsFavoritePresetFilenamesKey: @[],
            RoonVisSettingsHiddenPresetFilenamesKey: @[],
            // Tier-resolved defaults (HD: 720p@30, everything else 1080p@60).
            // Resolved once here at startup; both getters also clamp per tier.
            RoonVisSettingsFrameRateCapKey: @(RoonVisDefaultFrameRateForCurrentTier()),
            RoonVisSettingsDrawableSizePresetKey: DrawableSizePresetPersistedValue(RoonVisDefaultDrawablePresetForCurrentTier()),
            RoonVisSettingsSnapcastServerHostKey: InfoPlistSnapcastHost(),
        };
        [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
    });
}

- (NSUserDefaults *)defaults
{
    [RoonVisSettings registerDefaults];
    return [NSUserDefaults standardUserDefaults];
}

- (void)postChangeNotificationForKey:(NSString *)key
{
    [[NSNotificationCenter defaultCenter] postNotificationName:RoonVisSettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"key": key}];
}

- (NSInteger)rotationIntervalSeconds
{
    NSInteger value = [[self defaults] integerForKey:RoonVisSettingsRotationIntervalSecondsKey];
    return ClampIntegerToStep(value, kRotationIntervalMinimum, kRotationIntervalMaximum, kRotationIntervalStep);
}

- (void)setRotationIntervalSeconds:(NSInteger)rotationIntervalSeconds
{
    NSInteger clamped = ClampIntegerToStep(rotationIntervalSeconds, kRotationIntervalMinimum, kRotationIntervalMaximum, kRotationIntervalStep);
    if (self.rotationIntervalSeconds == clamped)
    {
        return;
    }
    [[self defaults] setInteger:clamped forKey:RoonVisSettingsRotationIntervalSecondsKey];
    RoonVisLog(@"Settings changed: rotationIntervalSeconds=%ld", static_cast<long>(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsRotationIntervalSecondsKey];
}

- (NSInteger)warpMeshWidth
{
    NSInteger value = [[self defaults] integerForKey:RoonVisSettingsWarpMeshWidthKey];
    return ClampIntegerToStep(value, kWarpMeshWidthMinimum, kWarpMeshWidthMaximum, kWarpMeshWidthStep);
}

- (void)setWarpMeshWidth:(NSInteger)warpMeshWidth
{
    NSInteger clamped = ClampIntegerToStep(warpMeshWidth, kWarpMeshWidthMinimum, kWarpMeshWidthMaximum, kWarpMeshWidthStep);
    if (self.warpMeshWidth == clamped)
    {
        return;
    }
    [[self defaults] setInteger:clamped forKey:RoonVisSettingsWarpMeshWidthKey];
    RoonVisLog(@"Settings changed: warpMeshWidth=%ld", static_cast<long>(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsWarpMeshWidthKey];
}

- (RoonVisPresetRotationMode)presetRotationMode
{
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *persistentDefaults = bundleIdentifier.length > 0 ? [[self defaults] persistentDomainForName:bundleIdentifier] : nil;
    id value = persistentDefaults[RoonVisSettingsPresetRotationModeKey];
    if (value == nil && bundleIdentifier.length == 0)
    {
        value = [[self defaults] objectForKey:RoonVisSettingsPresetRotationModeKey];
    }
    if ([value isKindOfClass:NSString.class])
    {
        NSString *mode = static_cast<NSString *>(value);
        if ([mode isEqualToString:kPresetRotationModeLoopValue])
        {
            return RoonVisPresetRotationModeLoop;
        }
        if ([mode isEqualToString:kPresetRotationModeFavoritesValue])
        {
            return RoonVisPresetRotationModeFavorites;
        }
        if ([mode isEqualToString:kPresetRotationModeShuffleValue])
        {
            return RoonVisPresetRotationModeShuffle;
        }
    }

    if ([[self defaults] boolForKey:RoonVisSettingsFavoritesOnlyRotationKey])
    {
        [[self defaults] setObject:kPresetRotationModeFavoritesValue forKey:RoonVisSettingsPresetRotationModeKey];
        return RoonVisPresetRotationModeFavorites;
    }
    return RoonVisPresetRotationModeShuffle;
}

- (void)setPresetRotationMode:(RoonVisPresetRotationMode)presetRotationMode
{
    NSString *mode = kPresetRotationModeShuffleValue;
    switch (presetRotationMode)
    {
        case RoonVisPresetRotationModeLoop:
            mode = kPresetRotationModeLoopValue;
            break;
        case RoonVisPresetRotationModeFavorites:
            mode = kPresetRotationModeFavoritesValue;
            break;
        case RoonVisPresetRotationModeShuffle:
            mode = kPresetRotationModeShuffleValue;
            break;
    }

    NSString *currentMode = kPresetRotationModeShuffleValue;
    switch (self.presetRotationMode)
    {
        case RoonVisPresetRotationModeLoop:
            currentMode = kPresetRotationModeLoopValue;
            break;
        case RoonVisPresetRotationModeFavorites:
            currentMode = kPresetRotationModeFavoritesValue;
            break;
        case RoonVisPresetRotationModeShuffle:
            currentMode = kPresetRotationModeShuffleValue;
            break;
    }
    if ([currentMode isEqualToString:mode])
    {
        return;
    }

    [[self defaults] setObject:mode forKey:RoonVisSettingsPresetRotationModeKey];
    RoonVisLog(@"Settings changed: presetRotationMode=%@", mode);
    [self postChangeNotificationForKey:RoonVisSettingsPresetRotationModeKey];
}

- (RoonVisTransitionStyle)transitionStyle
{
    NSString *style = [[self defaults] stringForKey:RoonVisSettingsTransitionStyleKey];
    if ([style isEqualToString:kTransitionStyleInstantValue])
    {
        return RoonVisTransitionStyleInstant;
    }
    return RoonVisTransitionStyleCrossfade;
}

- (void)setTransitionStyle:(RoonVisTransitionStyle)transitionStyle
{
    NSString *style = transitionStyle == RoonVisTransitionStyleInstant ? kTransitionStyleInstantValue : kTransitionStyleCrossfadeValue;
    NSString *currentStyle = self.transitionStyle == RoonVisTransitionStyleInstant ? kTransitionStyleInstantValue : kTransitionStyleCrossfadeValue;
    if ([currentStyle isEqualToString:style])
    {
        return;
    }
    [[self defaults] setObject:style forKey:RoonVisSettingsTransitionStyleKey];
    RoonVisLog(@"Settings changed: transitionStyle=%@", style);
    [self postChangeNotificationForKey:RoonVisSettingsTransitionStyleKey];
}

- (double)crossfadeDurationSeconds
{
    double value = [[self defaults] doubleForKey:RoonVisSettingsCrossfadeDurationSecondsKey];
    return ClampDoubleToStep(value, kCrossfadeDurationMinimum, kCrossfadeDurationMaximum, kCrossfadeDurationStep);
}

- (void)setCrossfadeDurationSeconds:(double)crossfadeDurationSeconds
{
    double clamped = ClampDoubleToStep(crossfadeDurationSeconds, kCrossfadeDurationMinimum, kCrossfadeDurationMaximum, kCrossfadeDurationStep);
    if (self.crossfadeDurationSeconds == clamped)
    {
        return;
    }
    [[self defaults] setDouble:clamped forKey:RoonVisSettingsCrossfadeDurationSecondsKey];
    RoonVisLog(@"Settings changed: crossfadeDurationSeconds=%.1f", clamped);
    [self postChangeNotificationForKey:RoonVisSettingsCrossfadeDurationSecondsKey];
}

- (double)beatHardCutSensitivity
{
    double value = [[self defaults] doubleForKey:RoonVisSettingsBeatHardCutSensitivityKey];
    return ClampDoubleToStep(value, kBeatHardCutSensitivityMinimum, kBeatHardCutSensitivityMaximum, kBeatHardCutSensitivityStep);
}

- (void)setBeatHardCutSensitivity:(double)beatHardCutSensitivity
{
    double clamped = ClampDoubleToStep(beatHardCutSensitivity, kBeatHardCutSensitivityMinimum, kBeatHardCutSensitivityMaximum, kBeatHardCutSensitivityStep);
    if (self.beatHardCutSensitivity == clamped)
    {
        return;
    }
    [[self defaults] setDouble:clamped forKey:RoonVisSettingsBeatHardCutSensitivityKey];
    RoonVisLog(@"Settings changed: beatHardCutSensitivity=%.2f", clamped);
    [self postChangeNotificationForKey:RoonVisSettingsBeatHardCutSensitivityKey];
}

- (double)audioSensitivity
{
    double value = [[self defaults] doubleForKey:RoonVisSettingsAudioSensitivityKey];
    return ClampDoubleToStep(value, kAudioSensitivityMinimum, kAudioSensitivityMaximum, kAudioSensitivityStep);
}

- (void)setAudioSensitivity:(double)audioSensitivity
{
    double clamped = ClampDoubleToStep(audioSensitivity, kAudioSensitivityMinimum, kAudioSensitivityMaximum, kAudioSensitivityStep);
    if (self.audioSensitivity == clamped)
    {
        return;
    }
    [[self defaults] setDouble:clamped forKey:RoonVisSettingsAudioSensitivityKey];
    RoonVisLog(@"Settings changed: audioSensitivity=%.1f", clamped);
    [self postChangeNotificationForKey:RoonVisSettingsAudioSensitivityKey];
}

- (NSInteger)audioInputDelayMs
{
    NSInteger value = [[self defaults] integerForKey:RoonVisSettingsAudioInputDelayMsKey];
    return ClampIntegerToStep(value, kAudioInputDelayMinimumMs, kAudioInputDelayMaximumMs, kAudioInputDelayStepMs);
}

- (void)setAudioInputDelayMs:(NSInteger)audioInputDelayMs
{
    NSInteger clamped = ClampIntegerToStep(audioInputDelayMs, kAudioInputDelayMinimumMs, kAudioInputDelayMaximumMs, kAudioInputDelayStepMs);
    if (self.audioInputDelayMs == clamped)
    {
        return;
    }
    [[self defaults] setInteger:clamped forKey:RoonVisSettingsAudioInputDelayMsKey];
    RoonVisLog(@"Settings changed: audioInputDelayMs=%ld", static_cast<long>(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsAudioInputDelayMsKey];
}

- (BOOL)isDiagnosticsOverlayEnabled
{
    return [[self defaults] boolForKey:RoonVisSettingsDiagnosticsOverlayEnabledKey];
}

- (void)setDiagnosticsOverlayEnabled:(BOOL)diagnosticsOverlayEnabled
{
    if (self.diagnosticsOverlayEnabled == diagnosticsOverlayEnabled)
    {
        return;
    }
    [[self defaults] setBool:diagnosticsOverlayEnabled forKey:RoonVisSettingsDiagnosticsOverlayEnabledKey];
    RoonVisLog(@"Settings changed: diagnosticsOverlayEnabled=%@", diagnosticsOverlayEnabled ? @"YES" : @"NO");
    [self postChangeNotificationForKey:RoonVisSettingsDiagnosticsOverlayEnabledKey];
}

- (NSInteger)frameRateCap
{
    NSInteger stored = [[self defaults] integerForKey:RoonVisSettingsFrameRateCapKey];
    if (stored <= 0)
    {
        stored = RoonVisDefaultFrameRateForCurrentTier();
    }
    return RoonVis::SnapFrameRateCap(static_cast<int>(stored));
}

- (void)setFrameRateCap:(NSInteger)frameRateCap
{
    NSInteger snapped = RoonVis::SnapFrameRateCap(static_cast<int>(frameRateCap));
    if (self.frameRateCap == snapped)
    {
        return;
    }
    [[self defaults] setInteger:snapped forKey:RoonVisSettingsFrameRateCapKey];
    RoonVisLog(@"Settings changed: frameRateCap=%ld", static_cast<long>(snapped));
    [self postChangeNotificationForKey:RoonVisSettingsFrameRateCapKey];
}

- (RoonVisDrawableSizePreset)drawableSizePreset
{
    id value = [[self defaults] objectForKey:RoonVisSettingsDrawableSizePresetKey];
    RoonVisDrawableSizePreset preset = RoonVisDefaultDrawablePresetForCurrentTier();
    if ([value isKindOfClass:NSString.class])
    {
        NSString *stored = static_cast<NSString *>(value);
        if ([stored isEqualToString:kDrawableSizePreset720pValue])
        {
            preset = RoonVisDrawableSizePreset720p;
        }
        else if ([stored isEqualToString:kDrawableSizePreset1080pValue])
        {
            preset = RoonVisDrawableSizePreset1080p;
        }
        else if ([stored isEqualToString:kDrawableSizePreset1440pValue])
        {
            preset = RoonVisDrawableSizePreset1440p;
        }
        else if ([stored isEqualToString:kDrawableSizePreset4KValue])
        {
            preset = RoonVisDrawableSizePreset4K;
        }
    }
    return ClampDrawableSizePresetToTier(preset);
}

- (void)setDrawableSizePreset:(RoonVisDrawableSizePreset)drawableSizePreset
{
    RoonVisDrawableSizePreset clamped = ClampDrawableSizePresetToTier(drawableSizePreset);
    if (self.drawableSizePreset == clamped)
    {
        return;
    }
    [[self defaults] setObject:DrawableSizePresetPersistedValue(clamped)
                        forKey:RoonVisSettingsDrawableSizePresetKey];
    RoonVisLog(@"Settings changed: drawableSizePreset=%@", RoonVisDrawableSizePresetLabel(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsDrawableSizePresetKey];
}

- (NSString *)snapcastServerHost
{
    NSString *stored = NormalizedHostOrEmpty([[self defaults] stringForKey:RoonVisSettingsSnapcastServerHostKey]);
    return stored.length > 0 ? stored : InfoPlistSnapcastHost();
}

- (void)setSnapcastServerHost:(NSString *)snapcastServerHost
{
    NSString *normalized = NormalizedHostOrEmpty(snapcastServerHost);
    if (normalized.length == 0)
    {
        normalized = InfoPlistSnapcastHost();
    }
    if ([self.snapcastServerHost isEqualToString:normalized])
    {
        return;
    }
    [[self defaults] setObject:normalized forKey:RoonVisSettingsSnapcastServerHostKey];
    RoonVisLog(@"Settings changed: snapcastServerHost=%@", normalized);
    [self postChangeNotificationForKey:RoonVisSettingsSnapcastServerHostKey];
}

- (NSSet<NSString *> *)favoritePresetFilenames
{
    return FilenameSetFromDefaultsValue([[self defaults] objectForKey:RoonVisSettingsFavoritePresetFilenamesKey]);
}

- (void)setFavoritePresetFilenames:(NSSet<NSString *> *)favoritePresetFilenames
{
    NSArray<NSString *> *filenames = SortedFilenameArrayFromSet(favoritePresetFilenames);
    NSArray<NSString *> *currentFilenames = SortedFilenameArrayFromSet(self.favoritePresetFilenames);
    if ([currentFilenames isEqualToArray:filenames])
    {
        return;
    }
    [[self defaults] setObject:filenames forKey:RoonVisSettingsFavoritePresetFilenamesKey];
    RoonVisLog(@"Settings changed: favoritePresetFilenames count=%lu", static_cast<unsigned long>(filenames.count));
    [self postChangeNotificationForKey:RoonVisSettingsFavoritePresetFilenamesKey];
}

- (NSSet<NSString *> *)hiddenPresetFilenames
{
    return FilenameSetFromDefaultsValue([[self defaults] objectForKey:RoonVisSettingsHiddenPresetFilenamesKey]);
}

- (void)setHiddenPresetFilenames:(NSSet<NSString *> *)hiddenPresetFilenames
{
    NSArray<NSString *> *filenames = SortedFilenameArrayFromSet(hiddenPresetFilenames);
    NSArray<NSString *> *currentFilenames = SortedFilenameArrayFromSet(self.hiddenPresetFilenames);
    if ([currentFilenames isEqualToArray:filenames])
    {
        return;
    }
    [[self defaults] setObject:filenames forKey:RoonVisSettingsHiddenPresetFilenamesKey];
    RoonVisLog(@"Settings changed: hiddenPresetFilenames count=%lu", static_cast<unsigned long>(filenames.count));
    [self postChangeNotificationForKey:RoonVisSettingsHiddenPresetFilenamesKey];
}

- (BOOL)isFavoritePresetFilename:(NSString *)filename
{
    return filename.length > 0 && [self.favoritePresetFilenames containsObject:filename];
}

- (void)addFavoritePresetFilename:(NSString *)filename
{
    if (filename.length == 0)
    {
        return;
    }
    NSMutableSet<NSString *> *filenames = [NSMutableSet setWithSet:self.favoritePresetFilenames];
    [filenames addObject:filename];
    self.favoritePresetFilenames = filenames;
}

- (void)removeFavoritePresetFilename:(NSString *)filename
{
    if (filename.length == 0)
    {
        return;
    }
    NSMutableSet<NSString *> *filenames = [NSMutableSet setWithSet:self.favoritePresetFilenames];
    [filenames removeObject:filename];
    self.favoritePresetFilenames = filenames;
}

- (BOOL)isHiddenPresetFilename:(NSString *)filename
{
    return filename.length > 0 && [self.hiddenPresetFilenames containsObject:filename];
}

- (void)addHiddenPresetFilename:(NSString *)filename
{
    if (filename.length == 0)
    {
        return;
    }
    NSMutableSet<NSString *> *filenames = [NSMutableSet setWithSet:self.hiddenPresetFilenames];
    [filenames addObject:filename];
    self.hiddenPresetFilenames = filenames;
}

- (void)removeHiddenPresetFilename:(NSString *)filename
{
    if (filename.length == 0)
    {
        return;
    }
    NSMutableSet<NSString *> *filenames = [NSMutableSet setWithSet:self.hiddenPresetFilenames];
    [filenames removeObject:filename];
    self.hiddenPresetFilenames = filenames;
}

@end
