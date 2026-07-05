#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PresetThumbnailRenderer : NSObject

+ (instancetype)sharedRenderer NS_SWIFT_NAME(shared());
- (void)thumbnailForPresetPath:(NSString *)path completion:(void (^)(UIImage *_Nullable image))completion NS_SWIFT_NAME(thumbnail(for:completion:));

@end

NS_ASSUME_NONNULL_END
