import SwiftUI
import UIKit

enum BrowseModalTab: Int {
    case favorites = 0
    case presets = 1
    case settings = 2
}

struct BrowseModalView: View {
    @ObservedObject var engine: EngineState
    @ObservedObject var settings: SettingsStore

    let onSelectPreset: (Int) -> Void
    let onToggleFavorite: (Int) -> Void
    let onHidePreset: (Int) -> Void
    let onDismiss: () -> Void
    let onCalibrateSync: () -> Void
    let onSelectedTabChange: (BrowseModalTab) -> Void

    @State private var selectedTab: BrowseModalTab
    // One-shot: only the FIRST PresetBrowserView shown grabs focus for the current
    // preset. Lives on the modal (not the browser view) because switching tabs
    // recreates PresetBrowserView, which would reset a per-view flag and re-yank focus.
    @State private var needsInitialPresetFocus = true
    @FocusState private var focusedTab: Int?
    @Namespace private var browseModalFocusNamespace

    init(
        engine: EngineState,
        settings: SettingsStore,
        initialTab: BrowseModalTab = .presets,
        onSelectPreset: @escaping (Int) -> Void,
        onToggleFavorite: @escaping (Int) -> Void,
        onHidePreset: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void,
        onCalibrateSync: @escaping () -> Void = {},
        onSelectedTabChange: @escaping (BrowseModalTab) -> Void = { _ in }
    ) {
        self.engine = engine
        self.settings = settings
        self.onSelectPreset = onSelectPreset
        self.onToggleFavorite = onToggleFavorite
        self.onHidePreset = onHidePreset
        self.onDismiss = onDismiss
        self.onCalibrateSync = onCalibrateSync
        self.onSelectedTabChange = onSelectedTabChange
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(RVTheme.Colors.scrim)
                .ignoresSafeArea()

            VStack(spacing: RVTheme.Spacing.l) {
                RVPillTabBar(
                    tabs: [
                        ("star.fill", "Favorites"),
                        ("waveform", "Presets"),
                        ("gearshape", "Settings"),
                    ],
                    selection: tabSelection,
                    focusedTab: $focusedTab
                )
                .padding(.top, RVTheme.Spacing.xl)
                // Full-width focus section so pressing Up from any card column can
                // reach the (horizontally centered, narrow) pill bar.
                .frame(maxWidth: .infinity)
                .focusSection()

                Group {
                    switch selectedTab {
                    case .favorites:
                        PresetBrowserView(
                            scope: .favorites,
                            engine: engine,
                            onSelectPreset: onSelectPreset,
                            onToggleFavorite: onToggleFavorite,
                            onHidePreset: onHidePreset,
                            initialFocusGrab: $needsInitialPresetFocus
                        )
                    case .presets:
                        PresetBrowserView(
                            scope: .allVisible,
                            engine: engine,
                            onSelectPreset: onSelectPreset,
                            onToggleFavorite: onToggleFavorite,
                            onHidePreset: onHidePreset,
                            initialFocusGrab: $needsInitialPresetFocus
                        )
                    case .settings:
                        SettingsScreenView(settings: settings, engine: engine, onCalibrateSync: onCalibrateSync)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, RVTheme.Spacing.xl)
        }
        .background(Color.clear)
        .focusScope(browseModalFocusNamespace)
        // Two-stage Menu (fix 4): first press retreats focus to the pill tab bar;
        // the second press (focus already on a pill) dismisses Browse. If focus is
        // somewhere with no pill focused (cards, Settings), Menu is stage 1.
        .onExitCommand {
            if focusedTab != nil {
                onDismiss()
            } else {
                focusedTab = selectedTab.rawValue
            }
        }
        // Directional entry into the pill bar (e.g. Up from a full-width Settings row)
        // lands on the geometrically nearest pill, not the selected tab's. Redirect any
        // content -> bar entry (nil -> some) onto the selected pill. Pill-to-pill moves
        // (some -> some) are left alone so Left/Right navigation still works.
        .onChange(of: focusedTab) { oldValue, newValue in
            if oldValue == nil, let entered = newValue, entered != selectedTab.rawValue {
                focusedTab = selectedTab.rawValue
            }
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab.rawValue },
            set: { newValue in
                guard let nextTab = BrowseModalTab(rawValue: newValue) else {
                    return
                }
                selectedTab = nextTab
                onSelectedTabChange(nextTab)
            }
        )
    }
}

private struct BrowseModalRootView: View {
    @StateObject private var settings: SettingsStore
    @StateObject private var engine: EngineState

    let onSelectPreset: (Int) -> Void
    let onToggleFavorite: (Int) -> Void
    let onHidePreset: (Int) -> Void
    let onDismiss: () -> Void
    let onCalibrateSync: () -> Void
    let onSelectedTabChange: (BrowseModalTab) -> Void
    let initialTab: BrowseModalTab

    init(
        settings: SettingsStore,
        engine: EngineState,
        initialTab: BrowseModalTab,
        onSelectPreset: @escaping (Int) -> Void,
        onToggleFavorite: @escaping (Int) -> Void,
        onHidePreset: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void,
        onCalibrateSync: @escaping () -> Void = {},
        onSelectedTabChange: @escaping (BrowseModalTab) -> Void
    ) {
        _settings = StateObject(wrappedValue: settings)
        _engine = StateObject(wrappedValue: engine)
        self.initialTab = initialTab
        self.onSelectPreset = onSelectPreset
        self.onToggleFavorite = onToggleFavorite
        self.onHidePreset = onHidePreset
        self.onDismiss = onDismiss
        self.onCalibrateSync = onCalibrateSync
        self.onSelectedTabChange = onSelectedTabChange
    }

    var body: some View {
        BrowseModalView(
            engine: engine,
            settings: settings,
            initialTab: initialTab,
            onSelectPreset: onSelectPreset,
            onToggleFavorite: onToggleFavorite,
            onHidePreset: onHidePreset,
            onDismiss: onDismiss,
            onCalibrateSync: onCalibrateSync,
            onSelectedTabChange: onSelectedTabChange
        )
    }
}

@objc final class BrowseModalFactory: NSObject {
    /// Menu from the visualizer ("Now Playing"): always open the playlist (Presets tab)
    /// focused on the current preset, regardless of the last-viewed tab (user issue #1).
    @objc(makePlaylistFocusedWithGlView:)
    @MainActor
    static func makePlaylistFocused(glView: ANGLEGLView) -> UIViewController {
        make(glView: glView, initialTab: .presets)
    }

    @objc(makeWithGlView:)
    @MainActor
    static func make(glView: ANGLEGLView) -> UIViewController {
        make(glView: glView, initialTab: glView.roonVisUIEnvironment.lastBrowseTab)
    }

    @MainActor
    static func make(glView: ANGLEGLView, initialTab: BrowseModalTab) -> UIViewController {
        let environment = glView.roonVisUIEnvironment
        let controller = UIHostingController(
            rootView: BrowseModalRootView(
                settings: environment.settings,
                engine: environment.engine,
                initialTab: initialTab,
                onSelectPreset: { index in
                    glView.selectPresetFromUI(at: UInt(index))
                },
                onToggleFavorite: { index in
                    glView.toggleFavoriteFromUI(at: UInt(index))
                },
                onHidePreset: { index in
                    glView.hidePresetFromUI(at: UInt(index))
                },
                onDismiss: {
                    glView.dismissBrowseFromUI()
                },
                onCalibrateSync: {
                    glView.presentSyncCalibrationFromUI()
                },
                onSelectedTabChange: { tab in
                    environment.lastBrowseTab = tab
                }
            )
        )
        controller.view.backgroundColor = .clear
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        return controller
    }
}

#Preview("Browse Modal", traits: .fixedLayout(width: 1920, height: 1080)) {
    BrowseModalView(
        engine: .preview(),
        settings: .preview(),
        initialTab: .presets,
        onSelectPreset: { _ in },
        onToggleFavorite: { _ in },
        onHidePreset: { _ in },
        onDismiss: {}
    )
}
