import SwiftUI
import UIKit

struct RootChromeView: View {
    @ObservedObject var engine: EngineState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var diagnostics: DiagnosticsState

    var body: some View {
        Group {
            if ProcessInfo.processInfo.environment["ROONVIS_UI_GALLERY"] == "1" {
                ComponentGalleryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if ProcessInfo.processInfo.environment["ROONVIS_UI_SETTINGS"] == "1" {
                ZStack {
                    RVTheme.Colors.background.opacity(0.62)
                    SettingsScreenView(settings: settings, engine: engine)
                }
            } else {
                ZStack {
                    if engine.warmup.active {
                        PresetWarmupCardView(text: engine.warmup.text)
                            .transition(.opacity)
                    }

                    VStack {
                        if engine.connectionState != .receivingAudio {
                            ConnectionCardView(state: engine.connectionState)
                                .transition(.opacity.combined(with: verticalTransition(edge: .top)))
                        }
                        Spacer()
                    }
                    .padding(.top, RVTheme.Spacing.l)

                    VStack {
                        Spacer()
                        if let toast = engine.toast {
                            NowPlayingToastView(toast: toast)
                                .transition(.opacity.combined(with: verticalTransition(edge: .bottom)))
                        }
                    }
                    .padding(.bottom, RVTheme.Spacing.xl)

                    VStack {
                        HStack {
                            Spacer()
                            if settings.diagnosticsOverlayEnabled {
                                DiagnosticsHUDView(
                                    fps: diagnostics.fps,
                                    frameMs: diagnostics.frameTimeMs,
                                    presetIndex: engine.currentPresetIndex,
                                    presetCount: engine.presetCount
                                )
                                .transition(.opacity)
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, RVTheme.Spacing.l)
                    .padding(.trailing, RVTheme.Spacing.xl)
                }
                .animation(.easeOut(duration: RVTheme.Anim.presentationDuration), value: engine.toast)
                .animation(.easeOut(duration: RVTheme.Anim.presentationDuration), value: engine.warmup)
                .animation(.easeOut(duration: RVTheme.Anim.presentationDuration), value: engine.connectionState)
                .animation(.easeOut(duration: RVTheme.Anim.presentationDuration), value: settings.diagnosticsOverlayEnabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private func verticalTransition(edge: Edge) -> AnyTransition {
        RVTheme.reduceMotion ? .identity : .move(edge: edge)
    }
}

private struct RootChromeRootView: View {
    @StateObject private var engine: EngineState
    @StateObject private var settings: SettingsStore
    @StateObject private var diagnostics: DiagnosticsState

    init(engine: EngineState, settings: SettingsStore, diagnostics: DiagnosticsState) {
        _engine = StateObject(wrappedValue: engine)
        _settings = StateObject(wrappedValue: settings)
        _diagnostics = StateObject(wrappedValue: diagnostics)
    }

    var body: some View {
        RootChromeView(engine: engine, settings: settings, diagnostics: diagnostics)
    }
}

@objc final class RootChromeFactory: NSObject {
    @objc(makeWithGlView:)
    @MainActor
    static func make(glView: ANGLEGLView) -> UIViewController {
        let environment = glView.roonVisUIEnvironment
        let controller = UIHostingController(
            rootView: RootChromeRootView(
                engine: environment.engine,
                settings: environment.settings,
                diagnostics: environment.diagnostics
            )
        )
        controller.view.backgroundColor = .clear
        return controller
    }
}

#Preview("Root Chrome - Active", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        LinearGradient(
            colors: [.black, .blue.opacity(0.45), .purple.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        RootChromeView(engine: .preview(), settings: .preview(), diagnostics: DiagnosticsState())
    }
}

#Preview("Root Chrome - Waiting", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        RVTheme.Colors.background
        RootChromeView(
            engine: .preview(
                connectionState: .waitingForConnection,
                isReady: false,
                presetName: nil,
                toast: nil,
                warmup: PresetWarmupState(active: true, text: "Preparing visualizer...")
            ),
            settings: .preview(diagnosticsEnabled: false),
            diagnostics: DiagnosticsState()
        )
    }
}
