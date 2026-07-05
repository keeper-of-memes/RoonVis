import SwiftUI

struct ComponentGalleryView: View {
    @State private var diagnosticsEnabled = false
    @State private var transitionSelection = 0
    @State private var rotationSeconds = 30.0
    @State private var crossfadeLength = 3.0
    @State private var reactivityLevel = 1.0
    @State private var tabSelection = 1
    @FocusState private var focusedTab: Int?

    var body: some View {
        GlassPanel(title: "Component Gallery", subtitle: "SwiftUI shared controls") {
            RVPillTabBar(
                tabs: [
                    (systemImage: "star.fill", title: "Favorites"),
                    (systemImage: "waveform", title: "Presets"),
                    (systemImage: "gearshape", title: "Settings")
                ],
                selection: $tabSelection,
                focusedTab: $focusedTab
            )
            .padding(.bottom, RVTheme.Spacing.xs)

            RVStepperRow(
                title: "Change presets every",
                value: $rotationSeconds,
                range: 5.0...120.0,
                step: 5.0
            ) { value in
                "\(Int(value)) sec"
            }

            RVSegmentRow(
                title: "Transition style",
                segments: ["Crossfade", "Instant cut"],
                selection: $transitionSelection
            )

            RVStepperRow(
                title: "Crossfade length",
                value: $crossfadeLength,
                range: SettingsRanges.crossfadeDuration,
                step: SettingsRanges.crossfadeDurationStep,
                formatter: formatSeconds
            )

            RVStepperRow(
                title: "Reactivity",
                value: $reactivityLevel,
                range: SettingsRanges.audioSensitivity,
                step: SettingsRanges.audioSensitivityStep,
                usesMonospacedValue: false,
                formatter: formatReactivity
            )

            RVToggleRow(
                title: "Diagnostics overlay",
                isOn: $diagnosticsEnabled
            )
        }
        .frame(maxWidth: 1160)
    }
}

#Preview("Component Gallery", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        RVTheme.Colors.background
        ComponentGalleryView()
    }
}
