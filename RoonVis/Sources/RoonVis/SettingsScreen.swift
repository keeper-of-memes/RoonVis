import SwiftUI

enum SettingsRanges {
    static let rotationInterval: ClosedRange<Double> = 60.0...900.0
    static let rotationIntervalStep = 60.0
    static let crossfadeDuration: ClosedRange<Double> = 1.0...5.0
    static let crossfadeDurationStep = 0.5
    static let beatHardCutSensitivity: ClosedRange<Double> = 0.0...1.0
    static let beatHardCutSensitivityStep = 0.05
    static let audioSensitivity: ClosedRange<Double> = 0.5...3.0
    static let audioSensitivityStep = 0.5
    static let audioInputDelay: ClosedRange<Double> = 0.0...500.0
    static let audioInputDelayStep = 5.0
    static let warpMesh: ClosedRange<Double> = 48.0...128.0
    static let warpMeshStep = 16.0
}

struct SettingsScreenView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineState
    var onCalibrateSync: () -> Void = {}
    @State private var isEditingHost = false
    @State private var hostDraft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: RVTheme.Spacing.l) {
                GlassPanel(title: "Rotation") {
                    RVStepperRow(
                        systemImage: "timer",
                        title: "Change presets every",
                        description: "How long each visual stays on screen before automatic rotation.",
                        value: rotationIntervalBinding,
                        range: SettingsRanges.rotationInterval,
                        step: SettingsRanges.rotationIntervalStep,
                        formatter: formatMinutes
                    )

                    RVSegmentRow(
                        systemImage: "arrow.triangle.2.circlepath",
                        title: "Preset Rotation",
                        description: "Choose how automatic and remote preset changes move through Browse.",
                        segments: ["Loop", "Shuffle", "Favourites"],
                        selection: presetRotationModeBinding
                    )
                }

                GlassPanel(title: "Transitions") {
                    RVSegmentRow(
                        systemImage: "rectangle.2.swap",
                        title: "Transition style",
                        description: "Choose the visual handoff between presets.",
                        segments: ["Crossfade", "Instant cut"],
                        selection: transitionStyleBinding
                    )

                    if settings.transitionStyle == .crossfade {
                        RVStepperRow(
                            systemImage: "slider.horizontal.below.rectangle",
                            title: "Crossfade length",
                            description: "Only applies when transition style is set to Crossfade.",
                            value: $settings.crossfadeDurationSeconds,
                            range: SettingsRanges.crossfadeDuration,
                            step: SettingsRanges.crossfadeDurationStep,
                            formatter: formatSeconds
                        )
                    }
                }

                GlassPanel(title: "Audio") {
                    RVStepperRow(
                        systemImage: "waveform.path.ecg",
                        title: "Beat-cut threshold",
                        description: "Higher values reserve hard cuts for stronger beat spikes.",
                        value: $settings.beatHardCutSensitivity,
                        range: SettingsRanges.beatHardCutSensitivity,
                        step: SettingsRanges.beatHardCutSensitivityStep,
                        formatter: formatPercent
                    )

                    RVStepperRow(
                        systemImage: "waveform",
                        title: "Reactivity",
                        description: "Subtle -> Wild controls how strongly music drives the visuals.",
                        value: $settings.audioSensitivity,
                        range: SettingsRanges.audioSensitivity,
                        step: SettingsRanges.audioSensitivityStep,
                        usesMonospacedValue: false,
                        formatter: formatReactivity
                    )

                    RVStepperRow(
                        systemImage: "metronome",
                        title: "Audio sync delay",
                        description: "How long the visualizer waits before reacting. Use Calibrate sync below to set this by ear; manual adjustment is optional.",
                        value: audioDelayBinding,
                        range: SettingsRanges.audioInputDelay,
                        step: SettingsRanges.audioInputDelayStep,
                        formatter: formatMilliseconds
                    )

                    RVFocusRow(
                        systemImage: "metronome.fill",
                        title: "Calibrate sync",
                        description: "Play rhythmic music, then nudge until the on-screen pulse matches what you hear. Calibrates your whole chain, including the TV.",
                        action: { onCalibrateSync() }
                    ) {
                        Text("Start")
                            .font(RVTheme.Fonts.caption.weight(.semibold))
                            .foregroundStyle(RVTheme.Colors.primaryText)
                            .padding(.horizontal, RVTheme.Spacing.m)
                            .frame(height: 54)
                            .background(RVTheme.Colors.accent, in: Capsule())
                    }
                    .accessibilityHint("Press Select to start sync calibration")
                }

                GlassPanel(title: "Rendering") {
                    RVSegmentRow(
                        systemImage: "speedometer",
                        title: "Frame rate",
                        description: "Caps the render rate. The actual rate follows the TV's refresh mode, so 25 and 50 only land exactly on 50 Hz output.",
                        segments: SettingsScreenView.allowedFrameRates.map { "\($0)" },
                        selection: frameRateCapBinding
                    )

                    RVSegmentRow(
                        systemImage: "sparkles.tv",
                        title: "Render quality",
                        description: "Rendering size before the TV scales it. Sizes above 1080p look sharper but may reduce the frame rate on complex presets.",
                        segments: allowedDrawablePresets.map { RoonVisDrawableSizePresetLabel($0) },
                        selection: drawableSizePresetBinding
                    )

                    RVStepperRow(
                        systemImage: "grid",
                        title: "Warp detail",
                        description: "Finer warp motion looks smoother but costs more per frame. Lower this if complex presets stutter; raise it for maximum detail.",
                        value: warpMeshBinding,
                        range: SettingsRanges.warpMesh,
                        step: SettingsRanges.warpMeshStep,
                        formatter: formatMesh
                    )
                }

                GlassPanel(title: "Connection") {
                    RVFocusRow(
                        systemImage: "network",
                        title: "Snapcast server",
                        description: "The Snapcast server that streams audio to the visualizer. IP address or hostname.",
                        action: {
                            hostDraft = settings.snapcastServerHost
                            isEditingHost = true
                        }
                    ) {
                        Text(settings.snapcastServerHost)
                            .font(RVTheme.Fonts.caption.monospaced())
                            .foregroundStyle(RVTheme.Colors.secondaryText)
                    }
                    .accessibilityHint("Press Select to edit the server address")
                }

                GlassPanel(title: "Diagnostics") {
                    RVToggleRow(
                        systemImage: "gauge.with.dots.needle.67percent",
                        title: "Diagnostics overlay",
                        description: "Show render and audio timing while tuning performance.",
                        isOn: $settings.diagnosticsOverlayEnabled
                    )
                }

                GlassPanel(title: "Hidden Presets") {
                    if sortedHiddenFilenames.isEmpty {
                        Text("No hidden presets. Hold Select on a preset in Browse and choose Hide; hidden presets appear here so you can restore them.")
                            .font(RVTheme.Fonts.caption)
                            .foregroundStyle(RVTheme.Colors.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, RVTheme.Spacing.s)
                    } else {
                        ForEach(sortedHiddenFilenames, id: \.self) { filename in
                            RVFocusRow(
                                systemImage: "eye.slash",
                                title: presetDisplayName(filename),
                                action: { settings.setHidden(filename, hidden: false) }
                            ) {
                                Text("Unhide")
                                    .font(RVTheme.Fonts.caption.weight(.semibold))
                                    .foregroundStyle(RVTheme.Colors.primaryText)
                                    .padding(.horizontal, RVTheme.Spacing.m)
                                    .frame(height: 54)
                                    .background(RVTheme.Colors.accent, in: Capsule())
                            }
                            .accessibilityHint("Press Select to unhide this preset")
                        }
                    }
                }
            }
            .frame(maxWidth: 1500)
            .padding(.horizontal, RVTheme.Spacing.xl)
            .padding(.vertical, RVTheme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .alert("Snapcast server", isPresented: $isEditingHost) {
            TextField("IP address or hostname", text: $hostDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") { settings.snapcastServerHost = hostDraft }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The visualizer reconnects immediately after saving. Clearing the field restores the built-in default.")
        }
    }

    private var sortedHiddenFilenames: [String] {
        settings.hiddenPresetFilenames.sorted()
    }

    private func presetDisplayName(_ filename: String) -> String {
        filename.hasSuffix(".milk") ? String(filename.dropLast(5)) : filename
    }

    private var rotationIntervalBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(settings.rotationIntervalSeconds) },
            set: { settings.rotationIntervalSeconds = Int($0.rounded()) }
        )
    }

    private var audioDelayBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(settings.audioInputDelayMs) },
            set: { settings.audioInputDelayMs = Int($0.rounded()) }
        )
    }

    private var warpMeshBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(settings.warpMeshWidth) },
            set: { settings.warpMeshWidth = Int($0.rounded()) }
        )
    }

    private var transitionStyleBinding: Binding<Int> {
        Binding<Int>(
            get: { settings.transitionStyle == .instant ? 1 : 0 },
            set: { settings.transitionStyle = $0 == 1 ? .instant : .crossfade }
        )
    }

    // The allowed frame-rate caps, matching RoonVis::SnapFrameRateCap's set.
    static let allowedFrameRates = [25, 30, 50, 60]

    // Drawable presets this device may select, capped by hardware tier (the
    // Apple TV HD tops out at 1080p). Bindings map through these stable enum
    // lists, never the raw segment index.
    private var allowedDrawablePresets: [RoonVisDrawableSizePreset] {
        let maxPreset = RoonVisMaxDrawablePresetForCurrentTier()
        let all: [RoonVisDrawableSizePreset] = [.preset720p, .preset1080p, .preset1440p, .preset4K]
        return all.filter { $0.rawValue <= maxPreset.rawValue }
    }

    private var frameRateCapBinding: Binding<Int> {
        Binding<Int>(
            get: {
                SettingsScreenView.allowedFrameRates.firstIndex(of: settings.frameRateCap) ?? (SettingsScreenView.allowedFrameRates.count - 1)
            },
            set: { index in
                let rates = SettingsScreenView.allowedFrameRates
                settings.frameRateCap = rates[max(0, min(index, rates.count - 1))]
            }
        )
    }

    private var drawableSizePresetBinding: Binding<Int> {
        Binding<Int>(
            get: {
                allowedDrawablePresets.firstIndex(of: settings.drawableSizePreset) ?? 0
            },
            set: { index in
                let presets = allowedDrawablePresets
                settings.drawableSizePreset = presets[max(0, min(index, presets.count - 1))]
            }
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
                default:
                    settings.presetRotationMode = .shuffle
                }
            }
        )
    }
}

func formatMinutes(_ value: Double) -> String {
    let minutes = Int((value / 60.0).rounded())
    return "\(minutes) min"
}

func formatSeconds(_ value: Double) -> String {
    String(format: "%.1f sec", value)
}

func formatPercent(_ value: Double) -> String {
    String(format: "%.0f%%", value * 100.0)
}

func formatReactivity(_ value: Double) -> String {
    if value <= 0.5 {
        return "Subtle"
    }
    if value <= 1.0 {
        return "Balanced"
    }
    if value <= 1.5 {
        return "Lively"
    }
    if value <= 2.0 {
        return "Bold"
    }
    if value <= 2.5 {
        return "Intense"
    }
    return "Wild"
}

func formatMilliseconds(_ value: Double) -> String {
    "\(Int(value.rounded())) ms"
}

func formatMesh(_ value: Double) -> String {
    let width = Int(value.rounded())
    let height = Int((value * 0.75).rounded())
    return "\(width) x \(height)"
}

#Preview("Settings", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        RVTheme.Colors.background
        SettingsScreenView(settings: .preview(), engine: .preview())
    }
}
