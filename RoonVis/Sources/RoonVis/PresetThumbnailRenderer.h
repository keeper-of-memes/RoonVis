#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PresetThumbnailRenderer : NSObject

+ (instancetype)sharedRenderer NS_SWIFT_NAME(shared());
- (void)thumbnailForPresetPath:(NSString *)path completion:(void (^)(UIImage *_Nullable image))completion NS_SWIFT_NAME(thumbnail(for:completion:));

// Cancels the live-render backlog: bumps a generation counter so queued jobs whose
// card scrolled away (or whose Browse modal was dismissed) skip the ~5s/3000-frame
// render and return nil early. Cache/bundled hits are fast and are not cancelled.
- (void)cancelPendingThumbnails;

@end

NS_ASSUME_NONNULL_END
