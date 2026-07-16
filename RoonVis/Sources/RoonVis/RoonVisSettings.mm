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
static NSString *const kPresetRotationModeCategoryValue = @"category";
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
{
    // Truth-in-memory: after -init these ivars ARE the settings; NSUserDefaults
    // is write-through persistence only. Nothing reads NSUserDefaults after
    // -init returns (all access is main-thread — no locking).
    NSInteger _rotationIntervalSeconds;
    RoonVisPresetRotationMode _rotationMode;
    RoonVisTransitionStyle _transitionStyle;
    double _crossfadeDurationSeconds;
    double _beatHardCutSensitivity;
    double _audioSensitivity;
    NSInteger _audioInputDelayMs;
    NSInteger _warpMeshWidth;
    BOOL _diagnosticsOverlayEnabled;
    NSInteger _frameRateCap;
    RoonVisDrawableSizePreset _drawableSizePreset;
    NSString *_snapcastServerHost;               // copied
    NSSet<NSString *> *_favoriteFilenames;       // immutable, retained
    NSSet<NSString *> *_hiddenFilenames;         // immutable, retained
    NSUInteger _librarySetsRevision;
}

+ (void)load
{
    [self registerDefaults];
}

- (instancetype)init
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }

    [RoonVisSettings registerDefaults];

    // THE ONLY defaults reads in the object's lifetime. Each mirrors the exact
    // (pre-truth-in-memory) getter logic, clamped so the ivar is valid; the
    // device tier is static per launch, so clamp-at-init+set keeps it valid.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    _rotationIntervalSeconds = ClampIntegerToStep([defaults integerForKey:RoonVisSettingsRotationIntervalSecondsKey],
                                                  kRotationIntervalMinimum, kRotationIntervalMaximum, kRotationIntervalStep);

    _rotationMode = [self resolveInitialRotationModeWithDefaults:defaults];

    {
        NSString *style = [defaults stringForKey:RoonVisSettingsTransitionStyleKey];
        _transitionStyle = [style isEqualToString:kTransitionStyleInstantValue] ? RoonVisTransitionStyleInstant
                                                                                : RoonVisTransitionStyleCrossfade;
    }

    _crossfadeDurationSeconds = ClampDoubleToStep([defaults doubleForKey:RoonVisSettingsCrossfadeDurationSecondsKey],
                                                  kCrossfadeDurationMinimum, kCrossfadeDurationMaximum, kCrossfadeDurationStep);

    _beatHardCutSensitivity = ClampDoubleToStep([defaults doubleForKey:RoonVisSettingsBeatHardCutSensitivityKey],
                                                kBeatHardCutSensitivityMinimum, kBeatHardCutSensitivityMaximum, kBeatHardCutSensitivityStep);

    _audioSensitivity = ClampDoubleToStep([defaults doubleForKey:RoonVisSettingsAudioSensitivityKey],
                                          kAudioSensitivityMinimum, kAudioSensitivityMaximum, kAudioSensitivityStep);

    _audioInputDelayMs = ClampIntegerToStep([defaults integerForKey:RoonVisSettingsAudioInputDelayMsKey],
                                            kAudioInputDelayMinimumMs, kAudioInputDelayMaximumMs, kAudioInputDelayStepMs);

    _warpMeshWidth = ClampIntegerToStep([defaults integerForKey:RoonVisSettingsWarpMeshWidthKey],
                                        kWarpMeshWidthMinimum, kWarpMeshWidthMaximum, kWarpMeshWidthStep);

    _diagnosticsOverlayEnabled = [defaults boolForKey:RoonVisSettingsDiagnosticsOverlayEnabledKey];

    {
        NSInteger stored = [defaults integerForKey:RoonVisSettingsFrameRateCapKey];
        if (stored <= 0)
        {
            stored = RoonVisDefaultFrameRateForCurrentTier();
        }
        _frameRateCap = RoonVis::SnapFrameRateCap(static_cast<int>(stored));
    }

    {
        id value = [defaults objectForKey:RoonVisSettingsDrawableSizePresetKey];
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
        _drawableSizePreset = ClampDrawableSizePresetToTier(preset);
    }

    {
        NSString *stored = NormalizedHostOrEmpty([defaults stringForKey:RoonVisSettingsSnapcastServerHostKey]);
        _snapcastServerHost = [(stored.length > 0 ? stored : InfoPlistSnapcastHost()) copy];
    }

    _favoriteFilenames = [FilenameSetFromDefaultsValue([defaults objectForKey:RoonVisSettingsFavoritePresetFilenamesKey]) copy];
    _hiddenFilenames = [FilenameSetFromDefaultsValue([defaults objectForKey:RoonVisSettingsHiddenPresetFilenamesKey]) copy];

    _librarySetsRevision = 0;

    return self;
}

// One-shot presetRotationMode migration. The registered default masks the
// "never set" state, so we probe the persistent domain (per commit 3862e610)
// to distinguish it and fall back to the legacy favoritesOnlyRotation bool.
// Runs EXACTLY ONCE (from -init), INCLUDING the write-back that makes the
// migration one-shot; the domain is never materialized again afterward.
- (RoonVisPresetRotationMode)resolveInitialRotationModeWithDefaults:(NSUserDefaults *)defaults
{
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSDictionary *persistentDefaults = bundleIdentifier.length > 0 ? [defaults persistentDomainForName:bundleIdentifier] : nil;
    id value = persistentDefaults[RoonVisSettingsPresetRotationModeKey];
    if (value == nil && bundleIdentifier.length == 0)
    {
        value = [defaults objectForKey:RoonVisSettingsPresetRotationModeKey];
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
        if ([mode isEqualToString:kPresetRotationModeCategoryValue])
        {
            return RoonVisPresetRotationModeCategory;
        }
    }

    if ([defaults boolForKey:RoonVisSettingsFavoritesOnlyRotationKey])
    {
        [defaults setObject:kPresetRotationModeFavoritesValue forKey:RoonVisSettingsPresetRotationModeKey];
        return RoonVisPresetRotationModeFavorites;
    }
    return RoonVisPresetRotationModeShuffle;
}

- (void)dealloc
{
    // The singleton never deallocs, but MRC hygiene is repo policy.
    [_snapcastServerHost release];
    [_favoriteFilenames release];
    [_hiddenFilenames release];
    [super dealloc];
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
            RoonVisSettingsAudioInputDelayMsKey: @(280),
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

- (void)postChangeNotificationForKey:(NSString *)key
{
    [[NSNotificationCenter defaultCenter] postNotificationName:RoonVisSettingsDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"key": key}];
}

- (NSInteger)rotationIntervalSeconds
{
    return _rotationIntervalSeconds;
}

- (void)setRotationIntervalSeconds:(NSInteger)rotationIntervalSeconds
{
    NSInteger clamped = ClampIntegerToStep(rotationIntervalSeconds, kRotationIntervalMinimum, kRotationIntervalMaximum, kRotationIntervalStep);
    if (_rotationIntervalSeconds == clamped)
    {
        return;
    }
    _rotationIntervalSeconds = clamped;
    [[NSUserDefaults standardUserDefaults] setInteger:clamped forKey:RoonVisSettingsRotationIntervalSecondsKey];
    RoonVisLog(@"Settings changed: rotationIntervalSeconds=%ld", static_cast<long>(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsRotationIntervalSecondsKey];
}

- (NSInteger)warpMeshWidth
{
    return _warpMeshWidth;
}

- (void)setWarpMeshWidth:(NSInteger)warpMeshWidth
{
    NSInteger clamped = ClampIntegerToStep(warpMeshWidth, kWarpMeshWidthMinimum, kWarpMeshWidthMaximum, kWarpMeshWidthStep);
    if (_warpMeshWidth == clamped)
    {
        return;
    }
    _warpMeshWidth = clamped;
    [[NSUserDefaults standardUserDefaults] setInteger:clamped forKey:RoonVisSettingsWarpMeshWidthKey];
    RoonVisLog(@"Settings changed: warpMeshWidth=%ld", static_cast<long>(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsWarpMeshWidthKey];
}

- (RoonVisPresetRotationMode)presetRotationMode
{
    return _rotationMode;
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
        case RoonVisPresetRotationModeCategory:
            mode = kPresetRotationModeCategoryValue;
            break;
    }

    NSString *currentMode = kPresetRotationModeShuffleValue;
    switch (_rotationMode)
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
        case RoonVisPresetRotationModeCategory:
            currentMode = kPresetRotationModeCategoryValue;
            break;
    }
    if ([currentMode isEqualToString:mode])
    {
        return;
    }

    _rotationMode = presetRotationMode;
    [[NSUserDefaults standardUserDefaults] setObject:mode forKey:RoonVisSettingsPresetRotationModeKey];
    RoonVisLog(@"Settings changed: presetRotationMode=%@", mode);
    [self postChangeNotificationForKey:RoonVisSettingsPresetRotationModeKey];
}

- (RoonVisTransitionStyle)transitionStyle
{
    return _transitionStyle;
}

- (void)setTransitionStyle:(RoonVisTransitionStyle)transitionStyle
{
    NSString *style = transitionStyle == RoonVisTransitionStyleInstant ? kTransitionStyleInstantValue : kTransitionStyleCrossfadeValue;
    NSString *currentStyle = _transitionStyle == RoonVisTransitionStyleInstant ? kTransitionStyleInstantValue : kTransitionStyleCrossfadeValue;
    if ([currentStyle isEqualToString:style])
    {
        return;
    }
    _transitionStyle = transitionStyle == RoonVisTransitionStyleInstant ? RoonVisTransitionStyleInstant : RoonVisTransitionStyleCrossfade;
    [[NSUserDefaults standardUserDefaults] setObject:style forKey:RoonVisSettingsTransitionStyleKey];
    RoonVisLog(@"Settings changed: transitionStyle=%@", style);
    [self postChangeNotificationForKey:RoonVisSettingsTransitionStyleKey];
}

- (double)crossfadeDurationSeconds
{
    return _crossfadeDurationSeconds;
}

- (void)setCrossfadeDurationSeconds:(double)crossfadeDurationSeconds
{
    double clamped = ClampDoubleToStep(crossfadeDurationSeconds, kCrossfadeDurationMinimum, kCrossfadeDurationMaximum, kCrossfadeDurationStep);
    if (_crossfadeDurationSeconds == clamped)
    {
        return;
    }
    _crossfadeDurationSeconds = clamped;
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:RoonVisSettingsCrossfadeDurationSecondsKey];
    RoonVisLog(@"Settings changed: crossfadeDurationSeconds=%.1f", clamped);
    [self postChangeNotificationForKey:RoonVisSettingsCrossfadeDurationSecondsKey];
}

- (double)beatHardCutSensitivity
{
    return _beatHardCutSensitivity;
}

- (void)setBeatHardCutSensitivity:(double)beatHardCutSensitivity
{
    double clamped = ClampDoubleToStep(beatHardCutSensitivity, kBeatHardCutSensitivityMinimum, kBeatHardCutSensitivityMaximum, kBeatHardCutSensitivityStep);
    if (_beatHardCutSensitivity == clamped)
    {
        return;
    }
    _beatHardCutSensitivity = clamped;
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:RoonVisSettingsBeatHardCutSensitivityKey];
    RoonVisLog(@"Settings changed: beatHardCutSensitivity=%.2f", clamped);
    [self postChangeNotificationForKey:RoonVisSettingsBeatHardCutSensitivityKey];
}

- (double)audioSensitivity
{
    return _audioSensitivity;
}

- (void)setAudioSensitivity:(double)audioSensitivity
{
    double clamped = ClampDoubleToStep(audioSensitivity, kAudioSensitivityMinimum, kAudioSensitivityMaximum, kAudioSensitivityStep);
    if (_audioSensitivity == clamped)
    {
        return;
    }
    _audioSensitivity = clamped;
    [[NSUserDefaults standardUserDefaults] setDouble:clamped forKey:RoonVisSettingsAudioSensitivityKey];
    RoonVisLog(@"Settings changed: audioSensitivity=%.1f", clamped);
    [self postChangeNotificationForKey:RoonVisSettingsAudioSensitivityKey];
}

- (NSInteger)audioInputDelayMs
{
    return _audioInputDelayMs;
}

- (void)setAudioInputDelayMs:(NSInteger)audioInputDelayMs
{
    NSInteger clamped = ClampIntegerToStep(audioInputDelayMs, kAudioInputDelayMinimumMs, kAudioInputDelayMaximumMs, kAudioInputDelayStepMs);
    if (_audioInputDelayMs == clamped)
    {
        return;
    }
    _audioInputDelayMs = clamped;
    [[NSUserDefaults standardUserDefaults] setInteger:clamped forKey:RoonVisSettingsAudioInputDelayMsKey];
    RoonVisLog(@"Settings changed: audioInputDelayMs=%ld", static_cast<long>(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsAudioInputDelayMsKey];
}

- (BOOL)isDiagnosticsOverlayEnabled
{
    return _diagnosticsOverlayEnabled;
}

- (void)setDiagnosticsOverlayEnabled:(BOOL)diagnosticsOverlayEnabled
{
    if (_diagnosticsOverlayEnabled == diagnosticsOverlayEnabled)
    {
        return;
    }
    _diagnosticsOverlayEnabled = diagnosticsOverlayEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:diagnosticsOverlayEnabled forKey:RoonVisSettingsDiagnosticsOverlayEnabledKey];
    RoonVisLog(@"Settings changed: diagnosticsOverlayEnabled=%@", diagnosticsOverlayEnabled ? @"YES" : @"NO");
    [self postChangeNotificationForKey:RoonVisSettingsDiagnosticsOverlayEnabledKey];
}

- (NSInteger)frameRateCap
{
    return _frameRateCap;
}

- (void)setFrameRateCap:(NSInteger)frameRateCap
{
    NSInteger snapped = RoonVis::SnapFrameRateCap(static_cast<int>(frameRateCap));
    if (_frameRateCap == snapped)
    {
        return;
    }
    _frameRateCap = snapped;
    [[NSUserDefaults standardUserDefaults] setInteger:snapped forKey:RoonVisSettingsFrameRateCapKey];
    RoonVisLog(@"Settings changed: frameRateCap=%ld", static_cast<long>(snapped));
    [self postChangeNotificationForKey:RoonVisSettingsFrameRateCapKey];
}

- (RoonVisDrawableSizePreset)drawableSizePreset
{
    return _drawableSizePreset;
}

- (void)setDrawableSizePreset:(RoonVisDrawableSizePreset)drawableSizePreset
{
    RoonVisDrawableSizePreset clamped = ClampDrawableSizePresetToTier(drawableSizePreset);
    if (_drawableSizePreset == clamped)
    {
        return;
    }
    _drawableSizePreset = clamped;
    [[NSUserDefaults standardUserDefaults] setObject:DrawableSizePresetPersistedValue(clamped)
                                              forKey:RoonVisSettingsDrawableSizePresetKey];
    RoonVisLog(@"Settings changed: drawableSizePreset=%@", RoonVisDrawableSizePresetLabel(clamped));
    [self postChangeNotificationForKey:RoonVisSettingsDrawableSizePresetKey];
}

- (NSString *)snapcastServerHost
{
    return _snapcastServerHost;
}

- (void)setSnapcastServerHost:(NSString *)snapcastServerHost
{
    NSString *normalized = NormalizedHostOrEmpty(snapcastServerHost);
    if (normalized.length == 0)
    {
        normalized = InfoPlistSnapcastHost();
    }
    if ([_snapcastServerHost isEqualToString:normalized])
    {
        return;
    }
    [_snapcastServerHost release];
    _snapcastServerHost = [normalized copy];
    [[NSUserDefaults standardUserDefaults] setObject:normalized forKey:RoonVisSettingsSnapcastServerHostKey];
    RoonVisLog(@"Settings changed: snapcastServerHost=%@", normalized);
    [self postChangeNotificationForKey:RoonVisSettingsSnapcastServerHostKey];
}

- (NSUInteger)librarySetsRevision
{
    return _librarySetsRevision;
}

- (NSSet<NSString *> *)favoritePresetFilenames
{
    return _favoriteFilenames;
}

- (void)setFavoritePresetFilenames:(NSSet<NSString *> *)favoritePresetFilenames
{
    NSArray<NSString *> *filenames = SortedFilenameArrayFromSet(favoritePresetFilenames);
    NSArray<NSString *> *currentFilenames = SortedFilenameArrayFromSet(_favoriteFilenames);
    if ([currentFilenames isEqualToArray:filenames])
    {
        return;
    }
    [_favoriteFilenames release];
    _favoriteFilenames = [[NSSet alloc] initWithArray:filenames];
    _librarySetsRevision++;
    [[NSUserDefaults standardUserDefaults] setObject:filenames forKey:RoonVisSettingsFavoritePresetFilenamesKey];
    RoonVisLog(@"Settings changed: favoritePresetFilenames count=%lu", static_cast<unsigned long>(filenames.count));
    [self postChangeNotificationForKey:RoonVisSettingsFavoritePresetFilenamesKey];
}

- (NSSet<NSString *> *)hiddenPresetFilenames
{
    return _hiddenFilenames;
}

- (void)setHiddenPresetFilenames:(NSSet<NSString *> *)hiddenPresetFilenames
{
    NSArray<NSString *> *filenames = SortedFilenameArrayFromSet(hiddenPresetFilenames);
    NSArray<NSString *> *currentFilenames = SortedFilenameArrayFromSet(_hiddenFilenames);
    if ([currentFilenames isEqualToArray:filenames])
    {
        return;
    }
    [_hiddenFilenames release];
    _hiddenFilenames = [[NSSet alloc] initWithArray:filenames];
    _librarySetsRevision++;
    [[NSUserDefaults standardUserDefaults] setObject:filenames forKey:RoonVisSettingsHiddenPresetFilenamesKey];
    RoonVisLog(@"Settings changed: hiddenPresetFilenames count=%lu", static_cast<unsigned long>(filenames.count));
    [self postChangeNotificationForKey:RoonVisSettingsHiddenPresetFilenamesKey];
}

- (BOOL)isFavoritePresetFilename:(NSString *)filename
{
    return filename.length > 0 && [_favoriteFilenames containsObject:filename];
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
    return filename.length > 0 && [_hiddenFilenames containsObject:filename];
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
