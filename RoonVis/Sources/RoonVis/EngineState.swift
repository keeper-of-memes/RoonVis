import Combine
import Foundation
import ObjectiveC

struct RemoteStatusToast: Equatable {
    var eyebrow: String
    var title: String
    var symbolName: String?
    var sticky: Bool
}

struct PresetWarmupState: Equatable {
    var active: Bool
    var text: String
}

@MainActor
final class EngineState: ObservableObject {
    @Published private(set) var connectionState: SnapcastClientConnectionState = .waitingForConnection
    @Published private(set) var isReady = false
    @Published private(set) var confirmedPresetName: String?
    @Published private(set) var requestedPresetName: String?
    @Published private(set) var presetRotationHeld = false
    @Published private(set) var currentPresetIndex = 0
    @Published private(set) var presetCount = 0
    @Published private(set) var toast: RemoteStatusToast?
    @Published private(set) var warmup = PresetWarmupState(active: true, text: "Preparing...")

    /// Single library-mutation signal. Mirrors RoonVisSettings.librarySetsRevision
    /// (bumped ONLY by the favorite/hidden set setters). The shelf cache and the
    /// browser views rebuild off this instead of a per-view refresh token, so the
    /// ~930ms shelf rebuild happens once per library change, not per tab-switch or
    /// per-toggle. Authoritative counter (never self-incremented) so a coalesced or
    /// missed notification can't drift it from the ObjC source of truth.
    @Published private(set) var libraryRevision = 0

    weak var glView: ANGLEGLView?

    /// Environment-scoped raw-shelf cache keyed by browse scope. Both tabs stay warm.
    /// An entry is valid while its (presetCount, libraryRevision) still match; on a
    /// mismatch the entry is rebuilt from the bridge (the expensive ObjC->Swift call).
    private struct RawShelfCacheEntry {
        let presetCount: Int
        let libraryRevision: Int
        let shelves: [RoonVisPresetShelf]
    }
    private var rawShelfCache: [PresetBrowserScope: RawShelfCacheEntry] = [:]

    private var bridgeObserver: NSObjectProtocol?
    private var connectionObserver: NSObjectProtocol?
    private var toastObserver: NSObjectProtocol?
    private var warmupObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var pendingToastClear: DispatchWorkItem?

    init() {
        connectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.SnapcastClientConnectionStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let stateValue = notification.userInfo?[SnapcastClientConnectionStateKey] as? NSNumber,
                let state = SnapcastClientConnectionState(rawValue: stateValue.intValue)
            else {
                return
            }
            Task { @MainActor in
                self?.updateConnectionState(state)
            }
        }

        toastObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.RoonVisRemoteStatus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateToast(from: notification)
            }
        }

        warmupObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.RoonVisPresetWarmup,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateWarmup(from: notification)
            }
        }

        bridgeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.RoonVisEngineStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateBridgeState(from: notification)
            }
        }

        // Library-mutation revision. The favorite/hidden setters post this notification
        // with userInfo["key"] == the changed key; only those two keys bump the
        // authoritative librarySetsRevision, so we filter on them and re-read the
        // counter rather than self-incrementing.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.RoonVisSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let key = notification.userInfo?["key"] as? String,
                key == RoonVisSettingsFavoritePresetFilenamesKey
                    || key == RoonVisSettingsHiddenPresetFilenamesKey
            else {
                return
            }
            Task { @MainActor in
                self?.updateLibraryRevision()
            }
        }
    }

    deinit {
        pendingToastClear?.cancel()
        if let bridgeObserver {
            NotificationCenter.default.removeObserver(bridgeObserver)
        }
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
        }
        if let toastObserver {
            NotificationCenter.default.removeObserver(toastObserver)
        }
        if let warmupObserver {
            NotificationCenter.default.removeObserver(warmupObserver)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    func attach(to view: ANGLEGLView) {
        glView = view
        snapshotBridgeState()
    }

    private func updateBridgeState(from notification: Notification) {
        guard let bridge = glView?.bridge else {
            snapshotBridgeState()
            return
        }
        guard notification.object as AnyObject? === bridge else { return }
        snapshotBridgeState()
    }

    private func snapshotBridgeState() {
        guard let bridge = glView?.bridge else {
            update(&isReady, false)
            update(&confirmedPresetName, nil)
            update(&requestedPresetName, nil)
            update(&presetRotationHeld, false)
            update(&currentPresetIndex, 0)
            update(&presetCount, 0)
            return
        }

        update(&isReady, bridge.isReady)
        update(&confirmedPresetName, bridge.confirmedPresetName)
        update(&requestedPresetName, bridge.requestedPresetName)
        update(&presetRotationHeld, bridge.presetRotationHeld)
        update(&currentPresetIndex, Int(bridge.currentPresetIndex()))
        update(&presetCount, Int(bridge.presetCount()))
    }

    private func updateLibraryRevision() {
        update(&libraryRevision, Int(RoonVisSettings.shared().librarySetsRevision))
    }

    /// Memoized raw shelves for a browse scope. The bridge call
    /// (`presetShelvesFavoritesOnly:`) is the ~930ms cost at CotC scale; we keep one
    /// warm entry per scope and only re-fetch when the pack size or library revision
    /// changed. The returned ObjC shelves are mapped to Swift view models by the view
    /// (cheap index copies), so this seam stays inside the bridge boundary.
    func rawShelves(scope: PresetBrowserScope) -> [RoonVisPresetShelf] {
        guard let bridge = glView?.bridge else {
            rawShelfCache[scope] = nil
            return []
        }
        if let entry = rawShelfCache[scope],
           entry.presetCount == presetCount,
           entry.libraryRevision == libraryRevision {
            return entry.shelves
        }
        let shelves = bridge.presetShelvesFavoritesOnly(scope.usesFavoritesOnly)
        rawShelfCache[scope] = RawShelfCacheEntry(
            presetCount: presetCount,
            libraryRevision: libraryRevision,
            shelves: shelves
        )
        return shelves
    }

    private func updateConnectionState(_ state: SnapcastClientConnectionState) {
        update(&connectionState, state)
    }

    private func updateToast(from notification: Notification) {
        pendingToastClear?.cancel()
        pendingToastClear = nil

        guard let title = notification.userInfo?[RoonVisRemoteStatusTitleKey] as? String, !title.isEmpty else {
            update(&toast, nil)
            return
        }

        let nextToast = RemoteStatusToast(
            eyebrow: (notification.userInfo?[RoonVisRemoteStatusEyebrowKey] as? String) ?? "Now Playing",
            title: title,
            symbolName: notification.userInfo?[RoonVisRemoteStatusSymbolKey] as? String,
            sticky: (notification.userInfo?[RoonVisRemoteStatusStickyKey] as? NSNumber)?.boolValue ?? false
        )
        update(&toast, nextToast)

        guard !nextToast.sticky else { return }
        let clear = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.toast = nil
            }
        }
        pendingToastClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: clear)
    }

    private func updateWarmup(from notification: Notification) {
        let active = (notification.userInfo?[RoonVisPresetWarmupActiveKey] as? NSNumber)?.boolValue ?? false
        let text = (notification.userInfo?[RoonVisPresetWarmupTextKey] as? String) ?? "Preparing..."
        update(&warmup, PresetWarmupState(active: active, text: text))
    }

    private func update<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
        if value != newValue {
            value = newValue
        }
    }
}

extension EngineState {
    static func preview(
        connectionState: SnapcastClientConnectionState = .receivingAudio,
        isReady: Bool = true,
        presetName: String? = "Geiss - Feedback Bloom",
        presetRotationHeld: Bool = false,
        currentPresetIndex: Int = 12,
        presetCount: Int = 248,
        toast: RemoteStatusToast? = RemoteStatusToast(
            eyebrow: "Now Playing",
            title: "Boards of Canada - Dayvan Cowboy",
            symbolName: "music.note",
            sticky: false
        ),
        warmup: PresetWarmupState = PresetWarmupState(active: false, text: "Preparing...")
    ) -> EngineState {
        let state = EngineState()
        state.connectionState = connectionState
        state.isReady = isReady
        state.confirmedPresetName = presetName
        state.requestedPresetName = nil
        state.presetRotationHeld = presetRotationHeld
        state.currentPresetIndex = currentPresetIndex
        state.presetCount = presetCount
        state.toast = toast
        state.warmup = warmup
        return state
    }
}

/// High-frequency render diagnostics (FPS / frame time), split out of EngineState so
/// that panels observing engine state (quick settings, settings, browse) do NOT
/// re-render on every 0.5s diagnostics tick — those re-renders were resetting focus
/// (the focused row snapped back to the first row). Only the diagnostics HUD observes
/// this object, and the HUD has no focusable content.
@MainActor
final class DiagnosticsState: ObservableObject {
    @Published private(set) var fps = 0.0
    @Published private(set) var frameTimeMs = 0.0
    @Published private(set) var droppedFrames = 0

    weak var glView: ANGLEGLView?
    private var timer: Timer?

    init() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        timer.tolerance = 0.1
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    func attach(to view: ANGLEGLView) {
        glView = view
        poll()
    }

    private func poll() {
        // No publishing while the HUD is hidden: the 0.5s tick still fires, but skipping
        // the read+publish avoids waking observers when nothing is on screen. The timer
        // itself is kept running (cheap; gating its creation/teardown adds lifecycle risk
        // for no measurable win).
        guard RoonVisSettings.shared().isDiagnosticsOverlayEnabled else { return }
        // Live sampler (RC feedback): hudCurrentFPS is a sample-and-reset window
        // over the frames since the previous poll, so the HUD is live from the
        // first tick instead of waiting on the 5s diagnostics window.
        let newFPS = glView?.hudCurrentFPS() ?? 0.0
        let newFrameMs = glView?.diagnosticsFrameTimeMs ?? 0.0
        let newDropped = Int(glView?.droppedFramesSincePresetChange ?? 0)
        if fps != newFPS { fps = newFPS }
        if frameTimeMs != newFrameMs { frameTimeMs = newFrameMs }
        if droppedFrames != newDropped { droppedFrames = newDropped }
    }
}

@MainActor
final class RoonVisUIEnvironment {
    let engine: EngineState
    let settings: SettingsStore
    let diagnostics: DiagnosticsState

    init(glView: ANGLEGLView) {
        engine = EngineState()
        engine.attach(to: glView)
        settings = SettingsStore()
        diagnostics = DiagnosticsState()
        diagnostics.attach(to: glView)
    }
}

private var roonVisUIEnvironmentKey: UInt8 = 0

extension ANGLEGLView {
    @MainActor
    var roonVisUIEnvironment: RoonVisUIEnvironment {
        if let environment = objc_getAssociatedObject(self, &roonVisUIEnvironmentKey) as? RoonVisUIEnvironment {
            return environment
        }

        let environment = RoonVisUIEnvironment(glView: self)
        objc_setAssociatedObject(
            self,
            &roonVisUIEnvironmentKey,
            environment,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return environment
    }
}
