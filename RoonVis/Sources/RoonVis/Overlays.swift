import SwiftUI

struct NowPlayingToastView: View {
    let toast: RemoteStatusToast

    var body: some View {
        HStack(spacing: RVTheme.Spacing.m) {
            if let symbolName = toast.symbolName {
                Image(systemName: symbolName)
                    .font(RVTheme.Fonts.caption.weight(.bold))
                    .foregroundStyle(RVTheme.Colors.primaryText)
                    .frame(width: 58, height: 58)
                    .background(RVTheme.Colors.strongMaterial)
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(toast.eyebrow)
                    .font(RVTheme.Fonts.caption)
                    .foregroundStyle(RVTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(toast.title)
                    .font(RVTheme.Fonts.body.weight(.bold))
                    .foregroundStyle(RVTheme.Colors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, RVTheme.Spacing.l)
        .padding(.vertical, RVTheme.Spacing.m)
        .frame(maxWidth: 980, alignment: .leading)
        .background(RVTheme.Colors.panelSurface, in: Capsule())   // solid dark, no glass
        .shadow(color: Color.black.opacity(0.32), radius: 30, y: 18)
        .allowsHitTesting(false)
    }
}

#Preview("Overlays", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        LinearGradient(
            colors: [.black, .cyan.opacity(0.28), .indigo.opacity(0.38)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        VStack(spacing: RVTheme.Spacing.xl) {
            ConnectionCardView(state: .waitingForConnection)
            PresetWarmupCardView(text: "Preparing visualizer...")
            NowPlayingToastView(
                toast: RemoteStatusToast(
                    eyebrow: "Now Playing",
                    title: "Jon Hopkins - Open Eye Signal",
                    symbolName: "music.note",
                    sticky: false
                )
            )
            DiagnosticsHUDView(fps: 59.8, frameMs: 16.7, presetIndex: 12, presetCount: 248)
        }
    }
}

struct PresetWarmupCardView: View {
    let text: String

    var body: some View {
        VStack(spacing: RVTheme.Spacing.l) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(RVTheme.Colors.accent)
                .scaleEffect(1.55)
                .frame(width: 92, height: 92)

            Text(text)
                .font(RVTheme.Fonts.body.weight(.bold))
                .foregroundStyle(RVTheme.Colors.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 340, height: 340)
        .background(RVTheme.Colors.panelSurface, in: RoundedRectangle(cornerRadius: RVTheme.Radius.l, style: .continuous))
        .shadow(color: Color.black.opacity(0.34), radius: 34, y: 20)
        .allowsHitTesting(false)
    }
}

struct DiagnosticsHUDView: View {
    let fps: Double
    let frameMs: Double
    let presetIndex: Int
    let presetCount: Int
    var droppedFrames: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.xs) {
            // Live-sampled fps (0.5s poll window). The >=59 orange threshold was
            // wrong on 50Hz panels; compare against nothing absolute here — the
            // panel cap varies (25/30/50/60 seen across devices/modes).
            diagnosticsRow(label: "FPS:", value: String(format: "%.0f", fps), valueColor: RVTheme.Colors.primaryText)
                .accessibilityIdentifier("diagnostics.fps")
                .accessibilityValue(String(format: "%.0f", fps))
            diagnosticsRow(label: "Frame time:", value: String(format: "%.1fms", frameMs), valueColor: RVTheme.Colors.primaryText)
            diagnosticsRow(label: "Dropped:", value: "\(droppedFrames)", valueColor: droppedFrames > 0 ? .orange : RVTheme.Colors.primaryText)
                .accessibilityIdentifier("diagnostics.dropped")
                .accessibilityValue("\(droppedFrames)")
            diagnosticsRow(label: "Preset:", value: presetText, valueColor: RVTheme.Colors.primaryText)
        }
        .padding(.horizontal, RVTheme.Spacing.m)
        .padding(.vertical, RVTheme.Spacing.s)
        .background(RVTheme.Colors.panelSurface, in: RoundedRectangle(cornerRadius: RVTheme.Radius.m, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 22, y: 14)
        .allowsHitTesting(false)
    }

    private var presetText: String {
        guard presetCount > 0 else { return "0/0" }
        return "\(presetIndex)/\(presetCount)"
    }

    private func diagnosticsRow(label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: RVTheme.Spacing.m) {
            Text(label)
                .font(RVTheme.Fonts.monospacedValue)
                .foregroundStyle(RVTheme.Colors.secondaryText)
            Spacer(minLength: RVTheme.Spacing.l)
            Text(value)
                .font(RVTheme.Fonts.monospacedValue)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .frame(width: 460)
    }
}

struct ConnectionCardView: View {
    let state: SnapcastClientConnectionState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: RVTheme.Spacing.s) {
            Circle()
                .fill(RVTheme.Colors.accent)
                .frame(width: 18, height: 18)
                .opacity(reduceMotion ? 1.0 : (pulse ? 1.0 : 0.42))
                .shadow(color: RVTheme.Colors.accent.opacity(0.65), radius: 12)

            Text(message)
                .font(RVTheme.Fonts.caption.weight(.semibold))
                .foregroundStyle(RVTheme.Colors.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, RVTheme.Spacing.l)
        .padding(.vertical, RVTheme.Spacing.s)
        .background(RVTheme.Colors.panelSurface, in: Capsule())   // solid dark, no glass
        .shadow(color: Color.black.opacity(0.24), radius: 24, y: 14)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            pulse = true
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.45).repeatForever(autoreverses: true), value: pulse)
    }

    private var message: String {
        switch state {
        case .reconnecting:
            return "Reconnecting to Snapcast..."
        case .waitingForConnection:
            return "Waiting for Snapcast..."
        case .connectedWaitingForAudio:
            return "Waiting for audio..."
        case .receivingAudio:
            return ""
        @unknown default:
            return "Waiting for Snapcast..."
        }
    }
}
