// QA-only preset validation view. Compiled out of the shipping Release binary
// (ROONVIS_ENABLE_PRESET_VALIDATOR is defined for all configs except Release).
#if ROONVIS_ENABLE_PRESET_VALIDATOR

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PresetValidator : UIView

- (void)pause;
- (void)resume;

@end

NS_ASSUME_NONNULL_END

#endif  // ROONVIS_ENABLE_PRESET_VALIDATOR
