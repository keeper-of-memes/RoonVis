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
