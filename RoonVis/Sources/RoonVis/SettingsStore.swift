import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    var rotationIntervalSeconds: Int {
        get { previewValues?.rotationIntervalSeconds ?? settings.rotationIntervalSeconds }
        set { write(\.rotationIntervalSeconds, newValue) { settings.rotationIntervalSeconds = newValue } }
    }
    var transitionStyle: RoonVisTransitionStyle {
        get { previewValues?.transitionStyle ?? settings.transitionStyle }
        set { write(\.transitionStyle, newValue) { settings.transitionStyle = newValue } }
    }
    var crossfadeDurationSeconds: Double {
        get { previewValues?.crossfadeDurationSeconds ?? settings.crossfadeDurationSeconds }
        set { write(\.crossfadeDurationSeconds, newValue) { settings.crossfadeDurationSeconds = newValue } }
    }
    var beatHardCutSensitivity: Double {
        get { previewValues?.beatHardCutSensitivity ?? settings.beatHardCutSensitivity }
        set { write(\.beatHardCutSensitivity, newValue) { settings.beatHardCutSensitivity = newValue } }
    }
    var audioSensitivity: Double {
        get { previewValues?.audioSensitivity ?? settings.audioSensitivity }
        set { write(\.audioSensitivity, newValue) { settings.audioSensitivity = newValue } }
    }
    var audioInputDelayMs: Int {
        get { previewValues?.audioInputDelayMs ?? settings.audioInputDelayMs }
        set { write(\.audioInputDelayMs, newValue) { settings.audioInputDelayMs = newValue } }
    }
    var warpMeshWidth: Int {
        get { previewValues?.warpMeshWidth ?? settings.warpMeshWidth }
        set { write(\.warpMeshWidth, newValue) { settings.warpMeshWidth = newValue } }
    }
    var presetRotationMode: RoonVisPresetRotationMode {
        get { previewValues?.presetRotationMode ?? settings.presetRotationMode }
        set { write(\.presetRotationMode, newValue) { settings.presetRotationMode = newValue } }
    }
    var diagnosticsOverlayEnabled: Bool {
        get { previewValues?.diagnosticsOverlayEnabled ?? settings.isDiagnosticsOverlayEnabled }
        set { write(\.diagnosticsOverlayEnabled, newValue) { settings.isDiagnosticsOverlayEnabled = newValue } }
    }
    var favoritePresetFilenames: Set<String> {
        get { previewValues?.favoritePresetFilenames ?? Set(settings.favoritePresetFilenames) }
        set { write(\.favoritePresetFilenames, newValue) { settings.favoritePresetFilenames = newValue } }
    }
    var hiddenPresetFilenames: Set<String> {
        get { previewValues?.hiddenPresetFilenames ?? Set(settings.hiddenPresetFilenames) }
        set { write(\.hiddenPresetFilenames, newValue) { settings.hiddenPresetFilenames = newValue } }
    }

    private var settingsObserver: NSObjectProtocol?
    private let settings = RoonVisSettings.shared()
    private var previewValues: PreviewValues?

    init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.RoonVisSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    func toggleFavorite(_ filename: String) {
        if favoritePresetFilenames.contains(filename) {
            var filenames = favoritePresetFilenames
            filenames.remove(filename)
            favoritePresetFilenames = filenames
        } else {
            var filenames = favoritePresetFilenames
            filenames.insert(filename)
            favoritePresetFilenames = filenames
        }
    }

    func setHidden(_ filename: String, hidden: Bool) {
        var filenames = hiddenPresetFilenames
        if hidden {
            filenames.insert(filename)
        } else {
            filenames.remove(filename)
        }
        hiddenPresetFilenames = filenames
    }

    private func write<Value: Equatable>(_ keyPath: WritableKeyPath<PreviewValues, Value>, _ newValue: Value, persist: () -> Void) {
        if previewValues != nil {
            if previewValues![keyPath: keyPath] == newValue {
                return
            }
            objectWillChange.send()
            previewValues![keyPath: keyPath] = newValue
            return
        }

        objectWillChange.send()
        persist()
    }
}

private struct PreviewValues {
    var rotationIntervalSeconds: Int
    var transitionStyle: RoonVisTransitionStyle
    var crossfadeDurationSeconds: Double
    var beatHardCutSensitivity: Double
    var audioSensitivity: Double
    var audioInputDelayMs: Int
    var warpMeshWidth: Int
    var presetRotationMode: RoonVisPresetRotationMode
    var diagnosticsOverlayEnabled: Bool
    var favoritePresetFilenames: Set<String>
    var hiddenPresetFilenames: Set<String>

    init(settings: RoonVisSettings) {
        rotationIntervalSeconds = settings.rotationIntervalSeconds
        transitionStyle = settings.transitionStyle
        crossfadeDurationSeconds = settings.crossfadeDurationSeconds
        beatHardCutSensitivity = settings.beatHardCutSensitivity
        audioSensitivity = settings.audioSensitivity
        audioInputDelayMs = settings.audioInputDelayMs
        warpMeshWidth = settings.warpMeshWidth
        presetRotationMode = settings.presetRotationMode
        diagnosticsOverlayEnabled = settings.isDiagnosticsOverlayEnabled
        favoritePresetFilenames = Set(settings.favoritePresetFilenames)
        hiddenPresetFilenames = Set(settings.hiddenPresetFilenames)
    }
}

extension SettingsStore {
    static func preview(
        diagnosticsEnabled: Bool = true,
        presetRotationMode: RoonVisPresetRotationMode = .shuffle,
        transitionStyle: RoonVisTransitionStyle = .crossfade
    ) -> SettingsStore {
        let store = SettingsStore()
        store.previewValues = PreviewValues(settings: store.settings)
        store.rotationIntervalSeconds = 300
        store.transitionStyle = transitionStyle
        store.crossfadeDurationSeconds = 3.0
        store.beatHardCutSensitivity = 0.65
        store.audioSensitivity = 1.5
        store.audioInputDelayMs = 85
        store.warpMeshWidth = 96
        store.presetRotationMode = presetRotationMode
        store.diagnosticsOverlayEnabled = diagnosticsEnabled
        store.favoritePresetFilenames = ["milkdrop-preview-01.milk", "milkdrop-preview-03.milk"]
        store.hiddenPresetFilenames = []
        return store
    }
}
