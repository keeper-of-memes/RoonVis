#import "RoonVisTheme.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cfloat>
#include <cmath>

namespace
{
static UIFont *RVSystemFont(CGFloat size, UIFontWeight regularWeight, UIFontWeight boldWeight)
{
    return [UIFont systemFontOfSize:size weight:(UIAccessibilityIsBoldTextEnabled() ? boldWeight : regularWeight)];
}
}

@implementation RoonVisTheme

// 10-foot type scale (tvOS HIG DISTANCE-01/07): body >= 29pt, secondary >= 25pt,
// medium weight minimum (thin strokes vanish at distance). See tvos-design-guidelines.
+ (UIFont *)titleFont { return RVSystemFont(56.0, UIFontWeightBold, UIFontWeightHeavy); }
+ (UIFont *)headlineFont { return RVSystemFont(38.0, UIFontWeightSemibold, UIFontWeightBold); }
+ (UIFont *)bodyFont { return RVSystemFont(31.0, UIFontWeightMedium, UIFontWeightSemibold); }
+ (UIFont *)captionFont { return RVSystemFont(26.0, UIFontWeightMedium, UIFontWeightSemibold); }
+ (UIFont *)monospacedValueFont
{
    return [UIFont monospacedDigitSystemFontOfSize:30.0 weight:(UIAccessibilityIsBoldTextEnabled() ? UIFontWeightBold : UIFontWeightSemibold)];
}

+ (CGFloat)spacingXS { return 8.0; }
+ (CGFloat)spacingS { return 14.0; }
+ (CGFloat)spacingM { return 22.0; }
+ (CGFloat)spacingL { return 34.0; }
+ (CGFloat)spacingXL { return 52.0; }
+ (CGFloat)spacingXXL { return 76.0; }
+ (UIEdgeInsets)safeAreaContentInsets { return UIEdgeInsetsMake(60.0, 90.0, 60.0, 90.0); }

+ (CGFloat)cornerRadiusS { return 8.0; }
+ (CGFloat)cornerRadiusM { return 12.0; }
+ (CGFloat)cornerRadiusL { return 18.0; }
+ (CGFloat)focusCornerRadius { return 14.0; }

+ (UIColor *)backgroundColor { return [UIColor colorWithWhite:0.015 alpha:1.0]; }
+ (UIColor *)materialColor { return [UIColor colorWithWhite:(UIAccessibilityDarkerSystemColorsEnabled() ? 0.035 : 0.055) alpha:0.86]; }
+ (UIColor *)strongMaterialColor { return [UIColor colorWithWhite:(UIAccessibilityDarkerSystemColorsEnabled() ? 0.045 : 0.075) alpha:0.94]; }
+ (UIColor *)separatorColor { return [UIColor colorWithWhite:1.0 alpha:(UIAccessibilityDarkerSystemColorsEnabled() ? 0.40 : 0.22)]; }
+ (UIColor *)primaryTextColor { return UIColor.whiteColor; }
+ (UIColor *)secondaryTextColor { return [UIColor colorWithWhite:(UIAccessibilityDarkerSystemColorsEnabled() ? 0.95 : 0.86) alpha:1.0]; }
+ (UIColor *)mutedTextColor { return [UIColor colorWithWhite:(UIAccessibilityDarkerSystemColorsEnabled() ? 0.82 : 0.68) alpha:1.0]; }
+ (UIColor *)accentColor { return [UIColor colorWithRed:0.65 green:0.55 blue:0.98 alpha:1.0]; }
+ (UIColor *)accentPressedColor { return [UIColor colorWithRed:0.55 green:0.36 blue:0.96 alpha:1.0]; }

+ (UIBlurEffectStyle)materialBlurStyle { return UIBlurEffectStyleDark; }
+ (UIVisualEffect *)backdropEffect
{
    // Liquid Glass on tvOS 26+. The regular style refracts/lenses the live
    // visualizer behind overlays; falls back to the dark blur pre-26.
    if (@available(tvOS 26.0, *))
    {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        return glass;
    }
    return [UIBlurEffect effectWithStyle:[self materialBlurStyle]];
}
+ (CGFloat)materialDimAlpha { return 0.42; }
+ (BOOL)reduceMotionEnabled { return UIAccessibilityIsReduceMotionEnabled(); }
+ (NSTimeInterval)standardAnimationDuration { return [self reduceMotionEnabled] ? 0.0 : 0.18; }
+ (NSTimeInterval)presentationAnimationDuration { return [self reduceMotionEnabled] ? 0.0 : 0.20; }
+ (NSTimeInterval)focusAnimationDuration { return [self reduceMotionEnabled] ? 0.0 : 0.22; }
+ (CGFloat)focusScale { return 1.08; }
+ (CGFloat)focusLift { return 18.0; }
+ (CGFloat)focusShadowOpacity { return 0.42; }
+ (CGFloat)focusShadowRadius { return 28.0; }

@end
