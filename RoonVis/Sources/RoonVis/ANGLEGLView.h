#import <UIKit/UIKit.h>

@class ProjectMBridge;

NS_ASSUME_NONNULL_BEGIN

@interface ANGLEGLView : UIView

@property(nonatomic, readonly, nullable) ProjectMBridge *bridge;
@property(nonatomic, assign, readonly) double diagnosticsFPS;
@property(nonatomic, assign, readonly) double diagnosticsFrameTimeMs;

- (void)pause;
- (void)resume;
- (void)reconnectSnapcastNow;

@end

@interface ANGLEGLView (Controls)

- (void)setPresetRotationHeldFromUI:(BOOL)held;
- (void)dismissQuickSettingsFromUI;
- (void)dismissPresetOptionsFromUI;
- (void)selectPresetAtIndexFromUI:(NSUInteger)index NS_SWIFT_NAME(selectPresetFromUI(at:));
- (void)toggleFavoriteAtIndexFromUI:(NSUInteger)index NS_SWIFT_NAME(toggleFavoriteFromUI(at:));
- (void)hidePresetAtIndexFromUI:(NSUInteger)index NS_SWIFT_NAME(hidePresetFromUI(at:));
- (void)dismissBrowseFromUI;
// Sync calibration: entry (dismisses Browse first, gates on live PCM) and exit.
- (void)presentSyncCalibrationFromUI;
- (void)dismissSyncCalibrationSaving:(BOOL)save;

@end

FOUNDATION_EXPORT NSNotificationName const RoonVisRemoteStatusNotification;
FOUNDATION_EXPORT NSString *const RoonVisRemoteStatusEyebrowKey;
FOUNDATION_EXPORT NSString *const RoonVisRemoteStatusTitleKey;
FOUNDATION_EXPORT NSString *const RoonVisRemoteStatusSymbolKey;
FOUNDATION_EXPORT NSString *const RoonVisRemoteStatusStickyKey;

FOUNDATION_EXPORT NSNotificationName const RoonVisPresetWarmupNotification;
FOUNDATION_EXPORT NSString *const RoonVisPresetWarmupActiveKey;
FOUNDATION_EXPORT NSString *const RoonVisPresetWarmupTextKey;

NS_ASSUME_NONNULL_END
