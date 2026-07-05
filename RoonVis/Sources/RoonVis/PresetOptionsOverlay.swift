import SwiftUI
import UIKit

/// Long-press Select on the visualizer opens this overlay: quick actions for the
/// preset that is playing right now (favorite / hide) without opening Browse.
struct PresetOptionsOverlayView: View {
    @ObservedObject var engine: EngineState
    let isFavorite: (Int) -> Bool
    let onToggleFavorite: (Int) -> Void
    let onHidePreset: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Full-screen translucent backdrop: presented as a real modal (its own
            // focus environment), same pattern as Quick Settings.
            Rectangle()
                .fill(RVTheme.Colors.scrim)
                .ignoresSafeArea()

            VStack {
                GlassPanel(title: presetTitle, subtitle: "Preset Options") {
                    VStack(spacing: RVTheme.Spacing.m) {
                        favoriteRow
                        hideRow

                        Text("Menu to close")
                            .font(RVTheme.Fonts.caption)
                            .foregroundStyle(RVTheme.Colors.mutedText)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: 980)
                .accessibilityIdentifier("preset-options-overlay")
                Spacer(minLength: 0)
            }
            .padding(.top, RVTheme.Spacing.xxl)
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var presetTitle: String {
        engine.confirmedPresetName ?? engine.requestedPresetName ?? "No preset loaded"
    }

    private var currentIsFavorite: Bool {
        isFavorite(engine.currentPresetIndex)
    }

    private var favoriteRow: some View {
        RVFocusRow(
            systemImage: currentIsFavorite ? "star.slash" : "star",
            title: currentIsFavorite ? "Remove Favorite" : "Add Favorite",
            description: currentIsFavorite ? "Remove this preset from Favorites" : "Add this preset to Favorites",
            action: {
                // Read the CURRENT index at action time — rotation may have advanced
                // while the overlay was up.
                onToggleFavorite(engine.currentPresetIndex)
            }
        ) {
            Image(systemName: currentIsFavorite ? "star.slash" : "star.fill")
                .font(RVTheme.Fonts.caption.weight(.semibold))
                .foregroundStyle(RVTheme.Colors.primaryText)
                .frame(width: 72, height: 54)
                .background(RVTheme.Colors.strongMaterial, in: Capsule())
        }
        .accessibilityLabel(currentIsFavorite ? "Remove Favorite" : "Add Favorite")
    }

    private var hideRow: some View {
        RVFocusRow(
            systemImage: "eye.slash",
            title: "Hide Preset",
            description: "Never show this preset again",
            action: {
                onHidePreset(engine.currentPresetIndex)
            }
        ) {
            Image(systemName: "eye.slash")
                .font(RVTheme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Color.red)
                .frame(width: 72, height: 54)
                .background(RVTheme.Colors.strongMaterial, in: Capsule())
        }
        .accessibilityLabel("Hide Preset")
    }
}

private struct PresetOptionsOverlayRootView: View {
    @StateObject private var engine: EngineState
    let isFavorite: (Int) -> Bool
    let onToggleFavorite: (Int) -> Void
    let onHidePreset: (Int) -> Void
    let onDismiss: () -> Void

    init(
        engine: EngineState,
        isFavorite: @escaping (Int) -> Bool,
        onToggleFavorite: @escaping (Int) -> Void,
        onHidePreset: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _engine = StateObject(wrappedValue: engine)
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onHidePreset = onHidePreset
        self.onDismiss = onDismiss
    }

    var body: some View {
        PresetOptionsOverlayView(
            engine: engine,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            onHidePreset: onHidePreset,
            onDismiss: onDismiss
        )
    }
}

@objc final class PresetOptionsOverlayFactory: NSObject {
    @objc(makeWithGlView:)
    @MainActor
    static func make(glView: ANGLEGLView) -> UIViewController {
        let environment = glView.roonVisUIEnvironment
        let controller = UIHostingController(
            rootView: PresetOptionsOverlayRootView(
                engine: environment.engine,
                isFavorite: { index in
                    glView.bridge?.isFavorite(at: UInt(index)) ?? false
                },
                onToggleFavorite: { index in
                    glView.toggleFavoriteFromUI(at: UInt(index))
                    glView.dismissPresetOptionsFromUI()
                },
                onHidePreset: { index in
                    // ProjectMBridge auto-advances if the current preset is hidden —
                    // no skip logic needed here.
                    glView.hidePresetFromUI(at: UInt(index))
                    glView.dismissPresetOptionsFromUI()
                },
                onDismiss: {
                    glView.dismissPresetOptionsFromUI()
                }
            )
        )
        controller.view.backgroundColor = .clear
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        return controller
    }
}

#Preview("Preset Options", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        RVTheme.Colors.background
        PresetOptionsOverlayView(
            engine: .preview(),
            isFavorite: { _ in false },
            onToggleFavorite: { _ in },
            onHidePreset: { _ in },
            onDismiss: {}
        )
    }
}
