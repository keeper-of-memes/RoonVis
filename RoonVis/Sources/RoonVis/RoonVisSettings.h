#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RoonVisTransitionStyle) {
    RoonVisTransitionStyleCrossfade = 0,
    RoonVisTransitionStyleInstant = 1,
};

typedef NS_ENUM(NSInteger, RoonVisPresetRotationMode) {
    RoonVisPresetRotationModeLoop = 0,
    RoonVisPresetRotationModeShuffle = 1,
    RoonVisPresetRotationModeFavorites = 2,
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
@property(nonatomic, copy) NSSet<NSString *> *favoritePresetFilenames;
@property(nonatomic, copy) NSSet<NSString *> *hiddenPresetFilenames;

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
