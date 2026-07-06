#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Apple TV hardware tier, mirroring RoonVis::DeviceTier (DeviceTier.h) for
// ObjC/Swift consumers. Values ordered by capability.
typedef NS_ENUM(NSInteger, RoonVisDeviceTierValue) {
    RoonVisDeviceTierHD = 0,
    RoonVisDeviceTier4KGen1 = 1,
    RoonVisDeviceTier4KGen2 = 2,
    RoonVisDeviceTier4KGen3OrLater = 3,
};

// Render-target preset, mirroring RoonVis::DrawableSizePreset. Ordered so a
// tier cap is a simple <= comparison.
typedef NS_ENUM(NSInteger, RoonVisDrawableSizePreset) {
    RoonVisDrawableSizePreset720p = 0,
    RoonVisDrawableSizePreset1080p = 1,
    RoonVisDrawableSizePreset1440p = 2,
    RoonVisDrawableSizePreset4K = 3,
};

// Cached-on-first-use hardware tier for this device (sysctl hw.machine on
// device, SIMULATOR_MODEL_IDENTIFIER on the simulator).
FOUNDATION_EXPORT RoonVisDeviceTierValue RoonVisCurrentDeviceTier(void);

// Tier-derived policy values (thin wrappers over the pure C++ functions).
FOUNDATION_EXPORT RoonVisDrawableSizePreset RoonVisMaxDrawablePresetForCurrentTier(void);
FOUNDATION_EXPORT RoonVisDrawableSizePreset RoonVisDefaultDrawablePresetForCurrentTier(void);
FOUNDATION_EXPORT NSInteger RoonVisDefaultFrameRateForCurrentTier(void);
FOUNDATION_EXPORT NSInteger RoonVisDefaultWarpMeshWidthForCurrentTier(void);

// Pixel size for a preset (1280x720 ... 3840x2160).
FOUNDATION_EXPORT CGSize RoonVisDrawableSizeForPreset(RoonVisDrawableSizePreset preset);

// Short label for logging ("720p", "1080p", "1440p", "4K").
FOUNDATION_EXPORT NSString *RoonVisDrawableSizePresetLabel(RoonVisDrawableSizePreset preset);

NS_ASSUME_NONNULL_END
