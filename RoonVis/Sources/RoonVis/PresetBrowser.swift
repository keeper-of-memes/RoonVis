import SwiftUI
import UIKit

enum PresetBrowserScope: Hashable {
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
    let category: String?
    let indexes: [Int]
}

/// Top-category section: header + its sub-category rows, in catalog order.
private struct PresetSectionViewModel: Identifiable {
    let id: String
    let title: String?
    let shelves: [PresetShelfViewModel]
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

    @State private var shelves: [PresetShelfViewModel] = []
    @State private var sections: [PresetSectionViewModel] = []
    @State private var didCenterInitialFocus = false
    // Captured from the shelf list's ScrollViewReader so the initial focus grab can
    // scroll the target shelf into view (materializing its LazyVStack row) BEFORE
    // assigning FocusState — otherwise the target card may not exist yet and the
    // focus assignment silently no-ops.
    @State private var shelfScrollProxy: ScrollViewProxy?
    @FocusState private var focusedPresetIndex: Int?
    // Category chip filter (Presets tab, non-HD). nil = "All". Defaults once per
    // open to the playing preset's top category so Browse opens where the visuals
    // already are, not at 155 rows. @State resets when the tab switch recreates
    // this view, so each Presets-tab entry re-defaults to the current category.
    @State private var selectedCategory: String?
    @State private var didInitSelectedCategory = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: RVTheme.Spacing.m) {
                if showsCategoryChips {
                    categoryChipRow
                }
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
        // Library mutations (favorite / hide) flow through the settings notification
        // into engine.libraryRevision; that drives the shelf rebuild here. On the
        // Favorites tab this refreshes the list when a favorite is toggled, replacing
        // the old per-view refreshToken bump.
        .onChange(of: engine.libraryRevision) {
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
            // The toggle routes bridge -> settings setter -> notification ->
            // engine.libraryRevision -> onChange(rebuildShelves) above. No local bump.
            onToggleFavorite(focusedPresetIndex)
        }
    }

    // Raw shelves come from EngineState's environment-scoped cache. The expensive
    // ~930ms bridge conversion happens at most once per (presetCount, libraryRevision)
    // per scope (both tabs stay warm on the engine); mapping the already-built ObjC
    // shelves to view models here is cheap index copies, run on every advance.
    @State private var cachedRawShelves: [PresetShelfViewModel] = []

    private func rebuildShelves() {
        guard engine.glView?.bridge != nil else {
            shelves = []
            sections = []
            return
        }
        cachedRawShelves = engine.rawShelves(scope: scope).enumerated().map { offset, shelf in
            PresetShelfViewModel(
                id: "\(offset)-\(shelf.title)",
                title: shelf.title,
                category: shelf.category,
                indexes: shelf.presetIndexes.compactMap { number in
                    Int(truncating: number)
                }
            )
        }
        initSelectedCategoryIfNeeded()
        applyCategoryFilterAndNowPlaying()
    }

    /// Once per open (Presets tab, non-HD), default the chip to the playing
    /// preset's top category. When chips are hidden the filter is always "All".
    private func initSelectedCategoryIfNeeded() {
        guard !didInitSelectedCategory else { return }
        didInitSelectedCategory = true
        guard showsCategoryChips else {
            selectedCategory = nil
            return
        }
        let current = engine.currentPresetIndex
        if let category = cachedRawShelves.first(where: { $0.indexes.contains(current) })?.category,
           !category.isEmpty {
            selectedCategory = category
        } else {
            selectedCategory = nil
        }
    }

    /// Applies the category chip filter to the cached raw shelves (pure Swift, no
    /// bridge round-trip) and re-derives the Now Playing section. Called on every
    /// advance and on chip changes.
    private func applyCategoryFilterAndNowPlaying() {
        let filtered: [PresetShelfViewModel]
        if let category = selectedCategory {
            filtered = cachedRawShelves.filter { $0.category == category }
        } else {
            filtered = cachedRawShelves
        }
        applyNowPlaying(to: filtered)
    }

    private func applyNowPlaying(to raw: [PresetShelfViewModel]) {
        guard scope == .allVisible else {
            shelves = raw
            sections = Self.buildSections(from: raw)
            return
        }
        // Now Playing is always surfaced when the current preset is a real bundled
        // preset — even when the active category filter excludes its category, so
        // it stays an orientation anchor (locked decision: always show Now Playing).
        let current = engine.currentPresetIndex
        guard current >= 0, current < engine.presetCount else {
            shelves = raw
            sections = Self.buildSections(from: raw)
            return
        }

        // Now Playing keeps its dedupe invariant: the current index appears exactly
        // once across all shelves (duplicate indices break index-keyed focus/scroll).
        let nowPlaying = PresetShelfViewModel(id: "now-playing", title: "Now Playing", category: nil, indexes: [current])
        let rest = raw.compactMap { shelf -> PresetShelfViewModel? in
            let filtered = shelf.indexes.filter { $0 != current }
            return filtered.isEmpty ? nil : PresetShelfViewModel(id: shelf.id, title: shelf.title, category: shelf.category, indexes: filtered)
        }
        shelves = [nowPlaying] + rest
        sections = Self.buildSections(from: shelves)
    }

    // MARK: Category chips

    /// nil = "All", then each distinct non-empty top category in catalog order.
    /// Shelves arrive ordered by (category, subcategory), so first-appearance
    /// order IS the pack/catalog order the chips are shown in.
    private var categoryChips: [String?] {
        var seen = Set<String>()
        var chips: [String?] = [nil]
        for shelf in cachedRawShelves {
            guard let category = shelf.category, !category.isEmpty, !seen.contains(category) else { continue }
            seen.insert(category)
            chips.append(category)
        }
        return chips
    }

    /// Chips are a Presets-tab, multi-category affordance, gated purely on
    /// category diversity (> 2). Previously also hidden on the HD tier, whose
    /// allowlist was ~24 presets across 1-2 categories; the 2026-07-13 device
    /// campaign grew the HD allowlist to 513 presets across 10 categories, so
    /// the diversity guard alone now correctly surfaces chips on both tiers.
    private var showsCategoryChips: Bool {
        scope == .allVisible && categoryChips.count > 2
    }

    /// Horizontal chip strip under the pill bar: All + each top category. Selecting
    /// a chip filters the vertical shelf list to that category (pure Swift on the
    /// cached shelves — no bridge round-trip). Wrapped in focusSection() so Up
    /// leaves it to the pills and Down enters the shelves.
    private var categoryChipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: RVTheme.Spacing.s) {
                    ForEach(categoryChips.indices, id: \.self) { index in
                        let category = categoryChips[index]
                        Button {
                            guard selectedCategory != category else { return }
                            selectedCategory = category
                            applyCategoryFilterAndNowPlaying()
                        } label: {
                            CategoryChipLabel(title: category ?? "All", isSelected: selectedCategory == category)
                        }
                        .buttonStyle(PresetCardButtonStyle())
                        .id(Self.chipID(category))
                        .accessibilityLabel(category == nil ? "All categories" : "Filter by \(category!)")
                    }
                }
                .padding(.horizontal, RVTheme.Spacing.xl)
                .padding(.vertical, RVTheme.Spacing.xs)
            }
            // A horizontal ScrollView takes flexible height and would expand to fill
            // the column, shoving the shelves down. Pin it to the chip height (62 +
            // xs padding, with headroom for the 1.08 focus zoom).
            .frame(height: 86)
            // Reveal the selected chip: on open the default is the playing preset's
            // category, which is often scrolled off-screen — bring it into view so
            // "opens where you are" is visible, not just applied.
            .onChange(of: selectedCategory) {
                withAnimation(RVTheme.Anim.focus) {
                    proxy.scrollTo(Self.chipID(selectedCategory), anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.chipID(selectedCategory), anchor: .center)
            }
        }
        .focusSection()
    }

    private static func chipID(_ category: String?) -> String {
        category ?? "__all__"
    }

    /// Groups consecutive shelves by top category (shelves arrive ordered by
    /// (category, subcategory) from the catalog). Category-less shelves (Now
    /// Playing, author clusters, Favorites) become header-less sections.
    private static func buildSections(from shelves: [PresetShelfViewModel]) -> [PresetSectionViewModel] {
        var sections: [PresetSectionViewModel] = []
        var currentTitle: String?? = nil // outer nil = no section open
        var bucket: [PresetShelfViewModel] = []
        func flush() {
            guard let title = currentTitle, !bucket.isEmpty else { return }
            sections.append(PresetSectionViewModel(id: "section-\(title ?? "none")-\(sections.count)", title: title, shelves: bucket))
            bucket = []
        }
        for shelf in shelves {
            let category = shelf.category?.isEmpty == false ? shelf.category : nil
            if currentTitle == nil || category != currentTitle! {
                flush()
                currentTitle = .some(category)
            }
            bucket.append(shelf)
        }
        flush()
        return sections
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
            // (proxy captured below via .onAppear for the initial focus grab)
            LazyVStack(alignment: .leading, spacing: RVTheme.Spacing.xl) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: RVTheme.Spacing.l) {
                        if let sectionTitle = section.title {
                            Text(sectionTitle)
                                .font(RVTheme.Fonts.title)
                                .foregroundStyle(RVTheme.Colors.primaryText)
                                .lineLimit(1)
                                .padding(.leading, RVTheme.Spacing.xl)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.shelves) { shelf in
                            shelfRow(shelf, inSection: section.title)
                        }
                    }
                }
            }
            .padding(.top, RVTheme.Spacing.s)
            .padding(.bottom, RVTheme.Spacing.xxl)
            }
            // Capture the proxy so the initial focus grab (in moveFocusToCurrentPreset
            // IfNeeded) can scroll the target shelf into view before assigning focus.
            .onAppear { shelfScrollProxy = proxy }
            // Center the current preset's ROW the first time Browse focuses it; the
            // focus engine keeps the card visible horizontally within the row.
            .onChange(of: focusedPresetIndex) {
                guard !didCenterInitialFocus, let index = focusedPresetIndex else { return }
                didCenterInitialFocus = true
                guard let shelfID = shelves.first(where: { $0.indexes.contains(index) })?.id else { return }
                withAnimation(RVTheme.Anim.focus) {
                    proxy.scrollTo(shelfID, anchor: .center)
                }
            }
        }
    }

    // One sub-category row: title + horizontally scrolling cards. focusSection()
    // makes up/down leave the row predictably (land on the nearest card of the
    // adjacent row) per the written focus map.
    private func shelfRow(_ shelf: PresetShelfViewModel, inSection sectionTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.m) {
            Text(shelf.title)
                .font(RVTheme.Fonts.headline)
                .foregroundStyle(RVTheme.Colors.secondaryText)
                .lineLimit(1)
                .padding(.leading, RVTheme.Spacing.xl)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: RVTheme.Spacing.l) {
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
                        .accessibilityIdentifier("preset-card-\(index)")
                        .contextMenu {
                            // Both actions route through the bridge -> settings setter
                            // -> notification -> engine.libraryRevision -> rebuild. No
                            // local refresh bump.
                            Button {
                                onToggleFavorite(index)
                            } label: {
                                Label(
                                    isFavorite(index) ? "Remove Favorite" : "Add Favorite",
                                    systemImage: isFavorite(index) ? "star.slash" : "star"
                                )
                            }
                            Button(role: .destructive) {
                                onHidePreset(index)
                            } label: {
                                Label("Hide Preset", systemImage: "eye.slash")
                            }
                        }
                    }
                }
                // Vertical padding gives the 1.12 focus scale room inside the
                // horizontal scroller; horizontal keeps cards off the screen edges.
                .padding(.horizontal, RVTheme.Spacing.xl)
                .padding(.vertical, RVTheme.Spacing.m)
            }
            .focusSection()
        }
        .id(shelf.id)
        .accessibilityIdentifier(shelf.id == "now-playing" ? "section-now-playing" : "preset-shelf")
        .accessibilityLabel(sectionTitle != nil ? "\(sectionTitle!) — \(shelf.title)" : shelf.title)
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
        guard let target = preferred else { return }
        // Explicit two-step grab so the target card is materialized before the
        // FocusState assignment (audit UI-3 — "Menu lands on the current card"):
        //   1. Scroll the target shelf into view NOW, so the LazyVStack row + its
        //      LazyHStack card exist. Without a materialized target view the
        //      FocusState assignment silently no-ops and focus falls back to the
        //      pill bar's prefersDefaultFocus.
        //   2. Assign focus on the NEXT runloop turn, after SwiftUI has laid out
        //      the freshly materialized card.
        if let shelfID = shelves.first(where: { $0.indexes.contains(target) })?.id {
            shelfScrollProxy?.scrollTo(shelfID, anchor: .center)
        }
        DispatchQueue.main.async {
            focusedPresetIndex = target
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

/// Category filter chip. Mirrors the rotation SegmentPill / pill-bar visual:
/// Capsule, accent fill when selected, focusFill when focused, zoom on focus.
private struct CategoryChipLabel: View {
    let title: String
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(title)
            .font(RVTheme.Fonts.caption.weight(isSelected || isFocused ? .semibold : .medium))
            .foregroundStyle(isSelected ? RVTheme.Colors.primaryText : RVTheme.Colors.primaryText.opacity(0.82))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, RVTheme.Spacing.l)
            .frame(height: 62)
            .background(chipBackground, in: Capsule())
            .scaleEffect(isFocused && !RVTheme.reduceMotion ? 1.08 : 1.0)
            .animation(RVTheme.Anim.focus, value: isFocused)
            .animation(RVTheme.Anim.focus, value: isSelected)
    }

    private var chipBackground: Color {
        if isSelected {
            return RVTheme.Colors.accent
        }
        if isFocused {
            return RVTheme.Colors.focusFill
        }
        return RVTheme.Colors.material
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
        // Bundled preview fast path: the pack ships PresetPreviews/<Top>/<Sub>/<stem>.jpg
        // mirroring presets/<Top>/<Sub>/<stem>.milk. The candidate path is a pure string
        // transform (synchronous on main); the fileExists check + decode both run off-main
        // in the detached task, so the main thread never touches the file system here.
        if let candidatePreviewPath = Self.candidateBundledPreviewPath(forPresetPath: path) {
            Task.detached(priority: .userInitiated) { [weak self] in
                if FileManager.default.fileExists(atPath: candidatePreviewPath),
                   let decoded = UIImage(contentsOfFile: candidatePreviewPath) {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        // Completed decodes always populate the cache, even if the card
                        // scrolled away; only the visible-image assignment stays guarded.
                        ThumbnailCache.shared.setImage(decoded, for: path)
                        if self.requestedPath == path {
                            self.image = decoded
                        }
                    }
                    return
                }
                // No bundled preview: fall through to the renderer path from the task's
                // main hop (preserving the requestedPath guard semantics).
                await MainActor.run { [weak self] in
                    guard let self, self.requestedPath == path else { return }
                    self.renderThumbnail(path: path)
                }
            }
            return
        }
        renderThumbnail(path: path)
    }

    private func renderThumbnail(path: String) {
        PresetThumbnailRenderer.shared().thumbnail(for: path) { [weak self] thumbnail in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Cache the completed render before the stale guard so a scrolled-away
                // card still warms the cache. The renderer returns nil for aborted jobs,
                // so caching nil is impossible (setImage only on non-nil).
                if let thumbnail {
                    ThumbnailCache.shared.setImage(thumbnail, for: path)
                }
                guard self.requestedPath == path else { return }
                self.image = thumbnail
            }
        }
    }

    func cancel(path: String) {
        guard requestedPath == path else { return }
        // Only clear the request marker; do NOT nil `image`. load(path:) already resets
        // image on a path change, so a recycled cell can't show a stale image, and this
        // removes the guaranteed placeholder flash on lazy-recycle re-entry.
        requestedPath = nil
    }

    /// presets/<Top>/<Sub>/x.milk -> PresetPreviews/<Top>/<Sub>/x.jpg (candidate path
    /// only, pure string transform — existence is checked off-main by the caller).
    nonisolated static func candidateBundledPreviewPath(forPresetPath path: String) -> String? {
        guard let range = path.range(of: "/presets/") else { return nil }
        var preview = path
        preview.replaceSubrange(range, with: "/PresetPreviews/")
        if preview.hasSuffix(".milk") {
            preview = String(preview.dropLast(5)) + ".jpg"
        }
        return preview
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
