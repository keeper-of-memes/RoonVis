import SwiftUI
import UIKit

enum RVTheme {
    enum Fonts {
        static var title: Font {
            Font.system(size: 56.0, weight: UIAccessibility.isBoldTextEnabled ? .heavy : .bold)
        }

        static var headline: Font {
            Font.system(size: 38.0, weight: UIAccessibility.isBoldTextEnabled ? .bold : .semibold)
        }

        static var body: Font {
            Font.system(size: 31.0, weight: UIAccessibility.isBoldTextEnabled ? .semibold : .medium)
        }

        static var caption: Font {
            Font.system(size: 29.0, weight: UIAccessibility.isBoldTextEnabled ? .semibold : .medium)
        }

        // Stepper values: SF face (matches the labels — the `.monospaced` design read as a
        // "terminal font" mismatch) with monospaced DIGITS so numbers don't jitter.
        static var monospacedValue: Font {
            Font.system(size: 30.0, weight: UIAccessibility.isBoldTextEnabled ? .bold : .semibold)
                .monospacedDigit()
        }
    }

    enum Spacing {
        static let xs: CGFloat = 8.0
        static let s: CGFloat = 14.0
        static let m: CGFloat = 22.0
        static let l: CGFloat = 34.0
        static let xl: CGFloat = 52.0
        static let xxl: CGFloat = 76.0
    }

    enum Radius {
        static let s: CGFloat = 16.0
        static let m: CGFloat = 24.0
        static let l: CGFloat = 32.0
        static let xl: CGFloat = 40.0
        static let focus: CGFloat = 24.0
    }

    enum Colors {
        static let background = Color(white: 0.015)
        /// Near-opaque dark backdrop for full-screen modals. Guarantees chrome contrast
        /// regardless of the bright visualizer frame behind it.
        static let scrim = Color(white: 0.02, opacity: 0.88)
        /// SOLID dark panel/card surface. Replaces `.glassEffect(.regular)` (Liquid Glass),
        /// which renders LIGHT on-device (washout), is GPU-heavy over the live visualizer
        /// (lag), and renders differently in the Simulator vs the TV — so a solid colour is
        /// the only reliably verifiable surface. tvOS HIG DISTANCE-02 (dark, high contrast).
        static let panelSurface = Color(white: 0.12)
        static let material = Color(white: 1.0, opacity: UIAccessibility.isDarkerSystemColorsEnabled ? 0.14 : 0.10)
        static let strongMaterial = Color(white: 1.0, opacity: UIAccessibility.isDarkerSystemColorsEnabled ? 0.22 : 0.17)
        static let panelTint = Color(red: 0.65, green: 0.55, blue: 0.98, opacity: UIAccessibility.isDarkerSystemColorsEnabled ? 0.10 : 0.06)
        static let separator = Color(white: 1.0, opacity: UIAccessibility.isDarkerSystemColorsEnabled ? 0.16 : 0.10)
        // Translucent white so a focused row reads LIGHTER than an unfocused one when both
        // sit on panelSurface (no glass to lift it any more). Focus = brightness + zoom.
        static let focusFill = Color(white: 1.0, opacity: 0.22)
        static let focusRing = Color(white: 1.0, opacity: 0.92)
        static let primaryText = Color.white
        static let secondaryText = Color(white: UIAccessibility.isDarkerSystemColorsEnabled ? 0.95 : 0.86)
        static let mutedText = Color(white: UIAccessibility.isDarkerSystemColorsEnabled ? 0.82 : 0.68)
        // Lavender accent per the updatedui mockups (≈#A78BFA; pressed ≈#8B5CF6).
        // Keep in sync with RoonVisTheme.mm accentColor/accentPressedColor.
        static let accent = Color(red: 0.65, green: 0.55, blue: 0.98)
        static let accentPressed = Color(red: 0.55, green: 0.36, blue: 0.96)
    }

    enum Anim {
        static var standardDuration: TimeInterval { RVTheme.reduceMotion ? 0.0 : 0.18 }
        static var presentationDuration: TimeInterval { RVTheme.reduceMotion ? 0.0 : 0.20 }
        static var focusDuration: TimeInterval { RVTheme.reduceMotion ? 0.0 : 0.22 }
        static var focus: Animation { .easeOut(duration: focusDuration) }

        static let focusScale: CGFloat = 1.12
        static let focusLift: CGFloat = 22.0
        static let focusShadowOpacity: Double = 0.42
        static let focusShadowRadius: CGFloat = 28.0
    }

    static var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}
