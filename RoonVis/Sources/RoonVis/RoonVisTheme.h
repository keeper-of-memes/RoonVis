#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RoonVisTheme : NSObject

+ (UIFont *)titleFont;
+ (UIFont *)headlineFont;
+ (UIFont *)bodyFont;
+ (UIFont *)captionFont;
+ (UIFont *)monospacedValueFont;

+ (CGFloat)spacingXS;
+ (CGFloat)spacingS;
+ (CGFloat)spacingM;
+ (CGFloat)spacingL;
+ (CGFloat)spacingXL;
+ (CGFloat)spacingXXL;
+ (UIEdgeInsets)safeAreaContentInsets;

+ (CGFloat)cornerRadiusS;
+ (CGFloat)cornerRadiusM;
+ (CGFloat)cornerRadiusL;
+ (CGFloat)focusCornerRadius;

+ (UIColor *)backgroundColor;
+ (UIColor *)materialColor;
+ (UIColor *)strongMaterialColor;
+ (UIColor *)separatorColor;
+ (UIColor *)primaryTextColor;
+ (UIColor *)secondaryTextColor;
+ (UIColor *)mutedTextColor;
+ (UIColor *)accentColor;
+ (UIColor *)accentPressedColor;

+ (UIBlurEffectStyle)materialBlurStyle;
// Liquid Glass (tvOS 26+) backdrop material, falling back to the dark blur on
// older systems. Use for full-screen overlay backdrops (browse, quick settings).
+ (UIVisualEffect *)backdropEffect;
+ (CGFloat)materialDimAlpha;
+ (BOOL)reduceMotionEnabled;
+ (NSTimeInterval)standardAnimationDuration;
+ (NSTimeInterval)presentationAnimationDuration;
+ (NSTimeInterval)focusAnimationDuration;
+ (CGFloat)focusScale;
+ (CGFloat)focusLift;
+ (CGFloat)focusShadowOpacity;
+ (CGFloat)focusShadowRadius;

@end

NS_ASSUME_NONNULL_END
