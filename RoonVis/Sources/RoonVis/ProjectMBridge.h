#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

BOOL RoonVisShouldSkipPresetThumbnail(NSString *presetFilename);

FOUNDATION_EXPORT NSNotificationName const RoonVisEngineStateDidChangeNotification;

@interface RoonVisPresetShelf : NSObject

@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *presetIndexes;

@end

@interface ProjectMBridge : NSObject

@property(nonatomic, readonly) BOOL isReady;
@property(nonatomic, readonly) BOOL presetRotationHeld;
@property(nonatomic, copy, readonly, nullable) NSString *confirmedPresetName;
@property(nonatomic, copy, readonly, nullable) NSString *requestedPresetName;
@property(nonatomic, readonly) NSInteger audioInputDelayMs;
// The buffer delay actually in use, which the latency lock trims below the user
// target as render time rises (see setEffectiveAudioDelayMs:). Call on the GL thread.
@property(nonatomic, readonly) NSInteger effectiveAudioDelayMs;
- (void)setEffectiveAudioDelayMs:(NSInteger)effectiveAudioDelayMs;

// --- Sync calibration (all main/GL thread; asserted) ---
// True while live Snapcast PCM is flowing (enqueue within the last 3 s) - the
// calibration entry gate. Never true for the bundled-WAV fallback.
@property(nonatomic, readonly) BOOL isLivePCMActive;
@property(nonatomic, readonly) BOOL syncCalibrationActive;
@property(nonatomic, readonly) NSInteger syncCalibrationDelayMs;
// Set when the onset detector fired within the samples consumed this frame;
// cleared at the start of each renderFrame.
@property(nonatomic, readonly) BOOL syncCalibrationOnsetThisFrame;
// Internal render compensation the latency lock adds on top of the user-visible
// delay setting (kept out of Settings/toasts by design - the user sees the
// number they aligned by ear).
@property(nonatomic, readonly) NSInteger syncRenderCompensationMs;
// Stashes target+effective delay and the rotation-hold state, holds rotation,
// pins the effective delay to the draft, resets the onset detector.
- (void)beginSyncCalibration;
// Live nudge: pins target == effective == ms (clamped 0-500) and rebases.
- (void)setSyncCalibrationDelayMs:(NSInteger)ms;
// Ends calibration. save=YES persists the render-compensated target computed
// from the caller-supplied running lock averages (see SyncCalibrationMath);
// save=NO restores the dual stash. Rotation-hold state is restored either way.
- (void)endSyncCalibrationSaving:(BOOL)save avgRenderMs:(double)avgRenderMs avgSwapMs:(double)avgSwapMs;

- (instancetype)initWithDrawableSize:(CGSize)drawableSize;
- (void)resizeToDrawableSize:(CGSize)drawableSize;
- (void)enqueueLivePCMInt16:(const int16_t *)interleaved frameCount:(NSUInteger)frameCount;
- (void)clearLivePCMBuffer;
- (NSUInteger)presetCount;
- (NSString *)presetFilenameAtIndex:(NSUInteger)index;
- (NSString *)presetDisplayNameAtIndex:(NSUInteger)index;
- (NSString *)presetPathAtIndex:(NSUInteger)index;
- (NSString *)presetBrowserTitleAtIndex:(NSUInteger)index NS_SWIFT_NAME(presetBrowserTitle(at:));
- (NSString *)presetPathForUIAtIndex:(NSUInteger)index NS_SWIFT_NAME(presetPathForUI(at:));
- (BOOL)isFavoriteAtIndex:(NSUInteger)index NS_SWIFT_NAME(isFavorite(at:));
- (NSArray<RoonVisPresetShelf *> *)presetShelvesFavoritesOnly:(BOOL)favoritesOnly;
- (NSInteger)currentPresetIndex;
- (BOOL)loadInitialPreset;
- (BOOL)selectPresetAtIndex:(NSUInteger)index smooth:(BOOL)smooth;
- (BOOL)selectNextPresetSmooth:(BOOL)smooth;
- (BOOL)selectPreviousPresetSmooth:(BOOL)smooth;
- (void)markPresetNameSlow:(NSString *)presetName catastrophic:(BOOL)catastrophic;
- (void)setPresetRotationHeld:(BOOL)held;
- (BOOL)isFavorite:(NSString *)presetFilename;
- (BOOL)toggleFavorite:(NSString *)presetFilename;
- (BOOL)isHidden:(NSString *)presetFilename;
- (void)hidePreset:(NSString *)presetFilename;
- (BOOL)renderFrame;

+ (void)markApplicationRunning;
+ (void)markApplicationCleanShutdown;

@end

NS_ASSUME_NONNULL_END
