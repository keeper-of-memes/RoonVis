import SwiftUI
import UIKit

enum PresetBrowserScope: Equatable {
    case favorites
    case allVisible

    var usesFavoritesOnly: Bool {
        self == .favorites
    }

    var emptyTitle: String {
        switch self {
        case .favorites:
            return "No favorites yet"
        case .allVisible:
            return "No presets available"
        }
    }

    var emptyMessage: String {
        switch self {
        case .favorites:
            return "Press Play on any preset to add it here."
        case .allVisible:
            return "All visible presets are hidden or unavailable."
        }
    }
}

private struct PresetShelfViewModel: Identifiable {
    let id: String
    let title: String
    let indexes: [Int]
}

struct PresetBrowserView: View {
    let scope: PresetBrowserScope
    @ObservedObject var engine: EngineState

    let onSelectPreset: (Int) -> Void
    let onToggleFavorite: (Int) -> Void
    let onHidePreset: (Int) -> Void

    /// One-shot flag owned by BrowseModalView: true only until the first browser view
    /// has grabbed focus for the current preset. Hoisted to the modal because the tab
    /// switch recreates PresetBrowserView (per-view @State would reset and re-yank).
    @Binding var initialFocusGrab: Bool

    @State private var refreshToken = 0
    @State private var shelves: [PresetShelfViewModel] = []
    @State private var didCenterInitialFocus = false
    @FocusState private var focusedPresetIndex: Int?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 400, maximum: 440), spacing: RVTheme.Spacing.l, alignment: .top)
    ]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: RVTheme.Spacing.m) {
                if shelves.isEmpty {
                    EmptyPresetBrowserView(
                        systemImage: scope == .favorites ? "star" : "rectangle.stack",
                        title: scope.emptyTitle,
                        message: scope.emptyMessage
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    shelfList
                }
            }
        }
        // Force the current preset (or first visible) to win initial focus over the tab
        // bar's prefersDefaultFocus — Menu from Now Playing must land ON the current card.
        // One-shot: after the initial grab the value is nil, so on tab switches the
        // pills' prefersDefaultFocus wins and focus stays on the tab bar.
        .defaultFocus($focusedPresetIndex, initialFocusGrab ? defaultFocusIndex : nil, priority: .userInitiated)
        .onAppear {
            rebuildShelves()
            if initialFocusGrab {
                moveFocusToCurrentPresetIfNeeded()
                initialFocusGrab = false
            }
        }
        .onChange(of: refreshToken) {
            rebuildShelves()
            ensureFocusedPresetIsVisible()
        }
        .onChange(of: scope) {
            rebuildShelves()
            ensureFocusedPresetIsVisible()
        }
        .onChange(of: engine.currentPresetIndex) {
            rebuildShelves()
            ensureFocusedPresetIsVisible()
        }
        .onChange(of: engine.presetCount) {
            rebuildShelves()
            ensureFocusedPresetIsVisible()
        }
        .onPlayPauseCommand {
            guard let focusedPresetIndex else { return }
            onToggleFavorite(focusedPresetIndex)
            refreshToken += 1
        }
    }

    private func rebuildShelves() {
        guard let bridge = engine.glView?.bridge else {
            shelves = []
            return
        }
        let raw = bridge.presetShelvesFavoritesOnly(scope.usesFavoritesOnly).enumerated().map { offset, shelf in
            PresetShelfViewModel(
                id: "\(offset)-\(shelf.title)",
                title: shelf.title,
                indexes: shelf.presetIndexes.compactMap { number in
                    Int(truncating: number)
                }
            )
        }

        // Presets tab only: surface the current preset in a "Now Playing" section at the top
        // and remove it from the artist shelves, so every preset appears exactly once (a
        // duplicate preset index breaks SwiftUI focus/scroll). Favourites live in the
        // Favourites tab; they appear here only within their artist shelves.
        guard scope == .allVisible else {
            shelves = raw
            return
        }
        let current = engine.currentPresetIndex
        guard raw.contains(where: { $0.indexes.contains(current) }) else {
            shelves = raw
            return
        }

        let nowPlaying = PresetShelfViewModel(id: "now-playing", title: "Now Playing", indexes: [current])
        let rest = raw.compactMap { shelf -> PresetShelfViewModel? in
            let filtered = shelf.indexes.filter { $0 != current }
            return filtered.isEmpty ? nil : PresetShelfViewModel(id: shelf.id, title: shelf.title, indexes: filtered)
        }
        shelves = [nowPlaying] + rest
    }

    private var visibleIndexes: [Int] {
        shelves.flatMap(\.indexes)
    }

    private var defaultFocusIndex: Int? {
        let visible = visibleIndexes
        guard !visible.isEmpty else { return nil }
        return visible.contains(engine.currentPresetIndex) ? engine.currentPresetIndex : visible.first
    }

    private var shelfList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: RVTheme.Spacing.xl) {
                ForEach(shelves) { shelf in
                    VStack(alignment: .leading, spacing: RVTheme.Spacing.m) {
                        Text(shelf.title)
                            .font(RVTheme.Fonts.headline)
                            .foregroundStyle(RVTheme.Colors.secondaryText)
                            .lineLimit(1)
                            .padding(.leading, RVTheme.Spacing.xl)

                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: RVTheme.Spacing.l) {
                            ForEach(shelf.indexes, id: \.self) { index in
                                PresetCardView(
                                    index: index,
                                    title: title(for: index),
                                    presetPath: presetPath(for: index),
                                    isFavorite: isFavorite(index),
                                    isFocused: focusedPresetIndex == index,
                                    onSelect: {
                                        onSelectPreset(index)
                                    }
                                )
                                .focused($focusedPresetIndex, equals: index)
                                .contextMenu {
                                    Button {
                                        onToggleFavorite(index)
                                        refreshToken += 1
                                    } label: {
                                        Label(
                                            isFavorite(index) ? "Remove Favorite" : "Add Favorite",
                                            systemImage: isFavorite(index) ? "star.slash" : "star"
                                        )
                                    }
                                    Button(role: .destructive) {
                                        onHidePreset(index)
                                        refreshToken += 1
                                    } label: {
                                        Label("Hide Preset", systemImage: "eye.slash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, RVTheme.Spacing.xl)
                    }
                    .accessibilityIdentifier(shelf.id == "now-playing" ? "section-now-playing" : "preset-shelf")
                }
            }
            .padding(.top, RVTheme.Spacing.s)
            .padding(.bottom, RVTheme.Spacing.xxl)
            }
            // Center the current preset the first time Browse focuses it (Menu-from-Now-
            // Playing opens the playlist here). Subsequent navigation is left to the tvOS
            // focus engine so we don't fight its scrolling.
            .onChange(of: focusedPresetIndex) {
                guard !didCenterInitialFocus, let index = focusedPresetIndex else { return }
                didCenterInitialFocus = true
                withAnimation(RVTheme.Anim.focus) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func title(for index: Int) -> String {
        engine.glView?.bridge?.presetBrowserTitle(at: UInt(index)) ?? "Visualizer \(index + 1)"
    }

    private func presetPath(for index: Int) -> String {
        engine.glView?.bridge?.presetPathForUI(at: UInt(index)) ?? ""
    }

    private func isFavorite(_ index: Int) -> Bool {
        engine.glView?.bridge?.isFavorite(at: UInt(index)) ?? false
    }

    private func moveFocusToCurrentPresetIfNeeded() {
        guard focusedPresetIndex == nil else { return }
        let preferred = visibleIndexes.contains(engine.currentPresetIndex) ? engine.currentPresetIndex : visibleIndexes.first
        DispatchQueue.main.async {
            focusedPresetIndex = preferred
        }
    }

    private func ensureFocusedPresetIsVisible() {
        let visible = visibleIndexes
        guard !visible.isEmpty else {
            focusedPresetIndex = nil
            return
        }
        // No card is focused (e.g. focus is on the pill bar): do NOT assign card focus —
        // that would yank focus away from the pills on every shelf rebuild.
        guard let focusedPresetIndex else { return }
        if visible.contains(focusedPresetIndex) {
            return
        }
        self.focusedPresetIndex = visible.contains(engine.currentPresetIndex) ? engine.currentPresetIndex : visible.first
    }
}

private struct PresetCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

private struct PresetCardView: View {
    let index: Int
    let title: String
    let presetPath: String
    let isFavorite: Bool
    let isFocused: Bool
    let onSelect: () -> Void

    @StateObject private var thumbnailLoader = ThumbnailLoader()

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: RVTheme.Spacing.s) {
                ZStack(alignment: .topTrailing) {
                    thumbnail
                        .frame(width: 400, height: 225)
                        .clipShape(RoundedRectangle(cornerRadius: RVTheme.Radius.m, style: .continuous))

                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(RVTheme.Colors.primaryText)
                            .frame(width: 46, height: 46)
                            .background(RVTheme.Colors.panelSurface)   // solid dark, no glass
                            .clipShape(Circle())
                            .padding(RVTheme.Spacing.s)
                    }
                }

                Text(title)
                    .font(RVTheme.Fonts.caption)
                    .foregroundStyle(RVTheme.Colors.primaryText)
                    .lineLimit(1)
                    .frame(width: 400, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        // A custom ButtonStyle (not .plain) opts out of the tvOS system white focus
        // frame; we show focus ourselves with zoom + accent glow below.
        .buttonStyle(PresetCardButtonStyle())
        .scaleEffect(isFocused && !RVTheme.reduceMotion ? 1.12 : 1.0)
        .shadow(
            color: isFocused && !RVTheme.reduceMotion ? RVTheme.Colors.accent.opacity(0.5) : Color.black.opacity(0.28),
            radius: isFocused && !RVTheme.reduceMotion ? 28 : 18,
            y: isFocused && !RVTheme.reduceMotion ? 18 : 10
        )
        .animation(RVTheme.Anim.focus, value: isFocused)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isFavorite ? "Press Select to play. Press Play/Pause to remove favorite." : "Press Select to play. Press Play/Pause to add favorite.")
        .onAppear {
            thumbnailLoader.load(path: presetPath)
        }
        .onChange(of: presetPath) {
            thumbnailLoader.load(path: presetPath)
        }
        .onDisappear {
            thumbnailLoader.cancel(path: presetPath)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = thumbnailLoader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: placeholderColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 74, weight: .bold))
                    .foregroundStyle(RVTheme.Colors.primaryText.opacity(0.72))
            }
        }
    }

    private var placeholderColors: [Color] {
        let hue = Double((index * 37) % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.74, brightness: 0.88),
            Color(hue: (hue + 0.13).truncatingRemainder(dividingBy: 1.0), saturation: 0.74, brightness: 0.88),
            Color(hue: hue, saturation: 0.74, brightness: 0.36),
        ]
    }

    private var accessibilityValue: String {
        isFavorite ? "Favorite" : ""
    }
}

private struct EmptyPresetBrowserView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: RVTheme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(RVTheme.Colors.secondaryText)
                .frame(width: 148, height: 148)

            Text(title)
                .font(RVTheme.Fonts.headline)
                .foregroundStyle(RVTheme.Colors.primaryText)

            Text(message)
                .font(RVTheme.Fonts.caption)
                .foregroundStyle(RVTheme.Colors.secondaryText)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    private var requestedPath: String?

    func load(path: String) {
        guard !path.isEmpty else {
            requestedPath = nil
            image = nil
            return
        }
        if requestedPath == path {
            return
        }
        requestedPath = path
        if let cached = ThumbnailCache.shared.image(for: path) {
            image = cached
            return
        }
        image = nil
        PresetThumbnailRenderer.shared().thumbnail(for: path) { [weak self] thumbnail in
            Task { @MainActor [weak self] in
                guard let self, self.requestedPath == path else { return }
                if let thumbnail {
                    ThumbnailCache.shared.setImage(thumbnail, for: path)
                }
                self.image = thumbnail
            }
        }
    }

    func cancel(path: String) {
        guard requestedPath == path else { return }
        requestedPath = nil
        image = nil
    }
}

#Preview("Preset Browser", traits: .fixedLayout(width: 1920, height: 1080)) {
    ZStack {
        RVTheme.Colors.background
        PresetBrowserView(
            scope: .allVisible,
            engine: .preview(),
            onSelectPreset: { _ in },
            onToggleFavorite: { _ in },
            onHidePreset: { _ in },
            initialFocusGrab: .constant(true)
        )
    }
}
