import SwiftUI
import UIKit

struct QuickSettingsPanelView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineState
    let onRotationPaused: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Full-screen translucent backdrop so the panel is presented as a real
            // modal (its own focus environment). Presenting as a subview overlay
            // instead left directional focus unable to traverse the rows.
            Rectangle()
                .fill(RVTheme.Colors.scrim)
                .ignoresSafeArea()

            VStack {
                GlassPanel(title: "Quick Settings") {
                    VStack(spacing: RVTheme.Spacing.m) {
                        rotationRow
                        presetRotationRow
                        transitionRow
                        reactivityRow
                        audioDelayRow
                        RVToggleRow(
                            systemImage: "gauge.with.dots.needle.67percent",
                            title: "Diagnostics overlay",
                            isOn: $settings.diagnosticsOverlayEnabled
                        )

                        Text("Menu to close")
                            .font(RVTheme.Fonts.caption)
                            .foregroundStyle(RVTheme.Colors.mutedText)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: 980)
                Spacer(minLength: 0)
            }
            .padding(.top, RVTheme.Spacing.xxl)
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var transitionRow: some View {
        RVSegmentRow(
            systemImage: "rectangle.2.swap",
            title: "Transition",
            segments: ["Crossfade", "Instant"],
            selection: transitionStyleBinding
        )
    }

    private var presetRotationRow: some View {
        RVSegmentRow(
            systemImage: "arrow.triangle.2.circlepath",
            title: "Preset Rotation",
            segments: ["Loop", "Shuffle", "Favourites", "Category"],
            selection: presetRotationModeBinding
        )
    }

    private var reactivityRow: some View {
        RVStepperRow(
            systemImage: "waveform",
            title: "Reactivity",
            value: $settings.audioSensitivity,
            range: SettingsRanges.audioSensitivity,
            step: SettingsRanges.audioSensitivityStep,
            usesMonospacedValue: false,
            formatter: formatReactivity
        )
    }

    private var audioDelayRow: some View {
        RVStepperRow(
            systemImage: "metronome",
            title: "Audio sync delay",
            value: audioDelayBinding,
            range: SettingsRanges.audioInputDelay,
            step: SettingsRanges.audioInputDelayStep,
            formatter: formatMilliseconds
        )
    }

    private var rotationRow: some View {
        RVFocusRow(systemImage: engine.presetRotationHeld ? "play.fill" : "pause.fill", title: rotationTitle, description: rotationDescription, action: {
            onRotationPaused(!engine.presetRotationHeld)
        }) {
            Image(systemName: engine.presetRotationHeld ? "play.fill" : "pause.fill")
                .font(RVTheme.Fonts.caption.weight(.semibold))
                .foregroundStyle(RVTheme.Colors.primaryText)
                .frame(width: 72, height: 54)
                .background(RVTheme.Colors.strongMaterial, in: Capsule())
        }
        .accessibilityLabel(rotationDescription)
    }

    private var rotationTitle: String {
        engine.presetRotationHeld ? "Rotation Paused" : "Rotation Active"
    }

    private var rotationDescription: String {
        engine.presetRotationHeld ? "Press Select to resume" : "Press Select to hold current preset"
    }

    private var audioDelayBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(settings.audioInputDelayMs) },
            set: { settings.audioInputDelayMs = Int($0.rounded()) }
        )
    }

    private var transitionStyleBinding: Binding<Int> {
        Binding<Int>(
            get: { settings.transitionStyle == .instant ? 1 : 0 },
            set: { settings.transitionStyle = $0 == 1 ? .instant : .crossfade }
        )
    }

    private var presetRotationModeBinding: Binding<Int> {
        Binding<Int>(
            get: {
                switch settings.presetRotationMode {
                case .loop:
                    return 0
                case .favorites:
                    return 2
                case .category:
                    return 3
                case .shuffle:
                    return 1
                @unknown default:
                    return 1
                }
            },
            set: { index in
                switch index {
                case 0:
                    settings.presetRotationMode = .loop
                case 2:
                    settings.presetRotationMode = .favorites
                case 3:
                    settings.presetRotationMode = .category
                default:
                    settings.presetRotationMode = .shuffle
                }
            }
        )
    }
}

private struct QuickSettingsPanelRootView: View {
    @StateObject private var settings: SettingsStore
    @StateObject private var engine: EngineState
    let onRotationPaused: (Bool) -> Void
    let onDismiss: () -> Void

    init(
        settings: SettingsStore,
        engine: EngineState,
        onRotationPaused: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _settings = StateObject(wrappedValue: settings)
        _engine = StateObject(wrappedValue: engine)
        self.onRotationPaused = onRotationPaused
        self.onDismiss = onDismiss
    }

    var body: some View {
        QuickSettingsPanelView(
            settings: settings,
            engine: engine,
            onRotationPaused: onRotationPaused,
            onDismiss: onDismiss
        )
    }
}

@objc final class QuickSettingsPanelFactory: NSObject {
    @objc(makeWithGlView:)
    @MainActor
    static func make(glView: ANGLEGLView) -> UIViewController {
        let environment = glView.roonVisUIEnvironment
        let controller = UIHostingController(
            rootView: QuickSettingsPanelRootView(
                settings: environment.settings,
                engine: environment.engine,
                onRotationPaused: { held in
                    glView.setPresetRotationHeldFromUI(held)
                },
                onDismiss: {
                    glView.dismissQuickSettingsFromUI()
                }
            )
        )
        controller.view.backgroundColor = .clear
        // Presented as a full-screen modal (see ANGLEGLView), matching Browse — a
        // real modal gives the panel its own focus environment so directional
        // focus can traverse the rows.
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        return controller
    }
}

#Preview("Quick Settings", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        RVTheme.Colors.background
        QuickSettingsPanelView(
            settings: .preview(),
            engine: .preview(),
            onRotationPaused: { _ in },
            onDismiss: {}
        )
    }
}
