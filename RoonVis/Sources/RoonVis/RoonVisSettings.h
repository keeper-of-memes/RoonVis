#import <Foundation/Foundation.h>

#import "RoonVisDeviceTier.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RoonVisTransitionStyle) {
    RoonVisTransitionStyleCrossfade = 0,
    RoonVisTransitionStyleInstant = 1,
};

typedef NS_ENUM(NSInteger, RoonVisPresetRotationMode) {
    RoonVisPresetRotationModeLoop = 0,
    RoonVisPresetRotationModeShuffle = 1,
    RoonVisPresetRotationModeFavorites = 2,
    // Shuffles within the playing preset's top category (pack tree). The
    // category follows the anchor preset; each category's order persists in
    // its own scope of the scoped rotation-order store (never the global
    // Shuffle scope "").
    RoonVisPresetRotationModeCategory = 3,
};

FOUNDATION_EXPORT NSNotificationName const RoonVisSettingsDidChangeNotification;

FOUNDATION_EXPORT NSString *const RoonVisSettingsRotationIntervalSecondsKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsPresetRotationModeKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsTransitionStyleKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsCrossfadeDurationSecondsKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsBeatHardCutSensitivityKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsAudioSensitivityKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsAudioInputDelayMsKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsWarpMeshWidthKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsFavoritesOnlyRotationKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsDiagnosticsOverlayEnabledKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsFavoritePresetFilenamesKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsHiddenPresetFilenamesKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsFrameRateCapKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsDrawableSizePresetKey;
FOUNDATION_EXPORT NSString *const RoonVisSettingsSnapcastServerHostKey;

@interface RoonVisSettings : NSObject

@property(nonatomic, assign) NSInteger rotationIntervalSeconds;
@property(nonatomic, assign) RoonVisPresetRotationMode presetRotationMode;
@property(nonatomic, assign) RoonVisTransitionStyle transitionStyle;
@property(nonatomic, assign) double crossfadeDurationSeconds;
@property(nonatomic, assign) double beatHardCutSensitivity;
@property(nonatomic, assign) double audioSensitivity;
@property(nonatomic, assign) NSInteger audioInputDelayMs;
// Warp-mesh grid width (height derived as width * 3/4). Higher = finer warp motion but
// more per-vertex CPU cost; heavy per-pixel presets scale hardest with this. Stepped
// 48..128 (see kWarpMeshWidth* in the .mm); 128 is the ceiling.
@property(nonatomic, assign) NSInteger warpMeshWidth;
@property(nonatomic, assign, getter=isDiagnosticsOverlayEnabled) BOOL diagnosticsOverlayEnabled;
// Frame-rate cap for the render display link, snapped to {25, 30, 50, 60}. The
// effective rate is min(screen max, cap); 25/50 only land exactly on 50 Hz
// output modes. Tier default: HD 30, everything else 60.
@property(nonatomic, assign) NSInteger frameRateCap;
// Render-target size preset, clamped on read AND write to the device tier's
// maximum (Apple TV HD tops out at 1080p). Tier default: HD 720p, others 1080p.
@property(nonatomic, assign) RoonVisDrawableSizePreset drawableSizePreset;
// Snapcast server host (IP or hostname). Defaults to the Info.plist
// SnapcastServerHost value; a cleared or invalid entry falls back to it.
// Normalized (trimmed, no embedded whitespace) on read and write.
@property(nonatomic, copy) NSString *snapcastServerHost;
@property(nonatomic, copy) NSSet<NSString *> *favoritePresetFilenames;
@property(nonatomic, copy) NSSet<NSString *> *hiddenPresetFilenames;

// Monotonically-increasing counter bumped whenever the favorite or hidden
// filename sets change. Lets observers cheaply detect library-set mutations
// (vs the scalar/string settings) without diffing the sets.
@property(nonatomic, readonly) NSUInteger librarySetsRevision;

+ (instancetype)sharedSettings;
+ (void)registerDefaults;

- (BOOL)isFavoritePresetFilename:(NSString *)filename;
- (void)addFavoritePresetFilename:(NSString *)filename;
- (void)removeFavoritePresetFilename:(NSString *)filename;

- (BOOL)isHiddenPresetFilename:(NSString *)filename;
- (void)addHiddenPresetFilename:(NSString *)filename;
- (void)removeHiddenPresetFilename:(NSString *)filename;

@end

NS_ASSUME_NONNULL_END
