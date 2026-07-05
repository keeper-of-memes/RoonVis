import SwiftUI

struct GlassPanel<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let content: Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: RVTheme.Spacing.l) {
            if title != nil || subtitle != nil {
                VStack(spacing: 6) {
                    if let title {
                        Text(title)
                            .font(RVTheme.Fonts.headline)
                            .foregroundStyle(RVTheme.Colors.primaryText)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(RVTheme.Fonts.caption)
                            .foregroundStyle(RVTheme.Colors.secondaryText)
                    }
                }
                .multilineTextAlignment(.center)
            }

            VStack(spacing: RVTheme.Spacing.m) {
                content
            }
            .focusSection()
        }
        .padding(.horizontal, RVTheme.Spacing.xl)
        .padding(.vertical, RVTheme.Spacing.l)
        .background {
            RoundedRectangle(cornerRadius: RVTheme.Radius.xl, style: .continuous)
                .fill(RVTheme.Colors.panelSurface)   // solid dark — no Liquid Glass (lag/washout)
        }
        .clipShape(RoundedRectangle(cornerRadius: RVTheme.Radius.xl, style: .continuous))
        .shadow(color: Color.black.opacity(0.5), radius: 40, y: 24)
    }
}

struct RVFocusRow<Control: View>: View {
    private let systemImage: String?
    private let title: String
    private let description: String?
    private let action: () -> Void
    private let control: Control

    init(
        systemImage: String? = nil,
        title: String,
        description: String? = nil,
        action: @escaping () -> Void = {},
        @ViewBuilder control: () -> Control
    ) {
        self.systemImage = systemImage
        self.title = title
        self.description = description
        self.action = action
        self.control = control()
    }

    var body: some View {
        Button(action: action) {
            RVRowChrome(systemImage: systemImage, title: title, description: description) {
                control
            }
        }
        .buttonStyle(RVRowButtonStyle())
    }
}

private struct RVRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.88 : 1.0)
    }
}

private struct RVRowChrome<Control: View>: View {
    let systemImage: String?
    let title: String
    let description: String?
    let isFocusedOverride: Bool?
    let control: Control

    @Environment(\.isFocused) private var environmentIsFocused

    init(
        systemImage: String?,
        title: String,
        description: String?,
        isFocusedOverride: Bool? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.systemImage = systemImage
        self.title = title
        self.description = description
        self.isFocusedOverride = isFocusedOverride
        self.control = control()
    }

    var body: some View {
        HStack(spacing: RVTheme.Spacing.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(RVTheme.Fonts.body)
                    .foregroundStyle(isFocused ? RVTheme.Colors.primaryText : RVTheme.Colors.secondaryText)
                    .frame(width: 66, height: 66)
                    .background(RVTheme.Colors.strongMaterial, in: RoundedRectangle(cornerRadius: RVTheme.Radius.s, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RVTheme.Fonts.body)
                    .foregroundStyle(RVTheme.Colors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let description {
                    Text(description)
                        .font(RVTheme.Fonts.caption)
                        .foregroundStyle(RVTheme.Colors.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Spacer(minLength: RVTheme.Spacing.m)

            control
        }
        .padding(.horizontal, RVTheme.Spacing.m)
        .frame(minHeight: 88)
        .background(
            isFocused ? RVTheme.Colors.focusFill : RVTheme.Colors.material,
            in: RoundedRectangle(cornerRadius: RVTheme.Radius.m, style: .continuous)
        )
        // Focus = a subtle fill lift + a real drop shadow + a modest zoom. No border, no glass.
        .shadow(
            color: Color.black.opacity(isFocused && !RVTheme.reduceMotion ? 0.5 : 0),
            radius: isFocused && !RVTheme.reduceMotion ? RVTheme.Anim.focusShadowRadius : 0,
            y: isFocused && !RVTheme.reduceMotion ? 20 : 0
        )
        .scaleEffect(isFocused && !RVTheme.reduceMotion ? 1.05 : 1.0)
        .offset(y: isFocused && !RVTheme.reduceMotion ? -RVTheme.Anim.focusLift : 0)
        .animation(RVTheme.Anim.focus, value: isFocused)
    }

    private var isFocused: Bool {
        isFocusedOverride ?? environmentIsFocused
    }
}

struct RVToggleRow: View {
    let systemImage: String?
    let title: String
    let description: String?
    @Binding var isOn: Bool

    init(systemImage: String? = nil, title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.systemImage = systemImage
        self.title = title
        self.description = description
        _isOn = isOn
    }

    var body: some View {
        RVFocusRow(systemImage: systemImage, title: title, description: description, action: {
            isOn.toggle()
        }) {
            RVSwitchVisual(isOn: isOn)
        }
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct RVSwitchVisual: View {
    let isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? RVTheme.Colors.accent : Color.white.opacity(0.18))
                .frame(width: 92, height: 54)
            Circle()
                .fill(RVTheme.Colors.primaryText)
                .frame(width: 44, height: 44)
                .shadow(color: Color.black.opacity(0.34), radius: 8, y: 4)
                .padding(.horizontal, 5)
        }
        .frame(width: 92, height: 54)
        .animation(reduceMotion ? nil : RVTheme.Anim.focus, value: isOn)
    }
}

struct RVSegmentRow: View {
    let systemImage: String?
    let title: String
    let description: String?
    let segments: [String]
    @Binding var selection: Int
    @FocusState private var focusedSegment: Int?

    init(
        systemImage: String? = nil,
        title: String,
        description: String? = nil,
        segments: [String],
        selection: Binding<Int>
    ) {
        self.systemImage = systemImage
        self.title = title
        self.description = description
        self.segments = segments
        _selection = selection
    }

    var body: some View {
        RVRowChrome(systemImage: systemImage, title: title, description: description, isFocusedOverride: focusedSegment != nil) {
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    Button {
                        selection = index
                        focusedSegment = index
                    } label: {
                        SegmentPill(
                            title: segments[index],
                            isSelected: selection == index,
                            isFocused: focusedSegment == index
                        )
                    }
                    .buttonStyle(RVRowButtonStyle())   // suppress the tvOS system white focus frame
                    .focused($focusedSegment, equals: index)
                }
            }
            .padding(4)
            .background(RVTheme.Colors.material, in: Capsule())
        }
        .onChange(of: focusedSegment) {
            if let focusedSegment {
                selection = focusedSegment
            }
        }
        .onChange(of: selection) {
            guard segments.indices.contains(selection), focusedSegment != selection else { return }
            focusedSegment = selection
        }
    }
}

private struct SegmentPill: View {
    let title: String
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        Text(title)
            .font(RVTheme.Fonts.caption)
            .foregroundStyle(isSelected ? RVTheme.Colors.primaryText : RVTheme.Colors.primaryText.opacity(0.82))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, RVTheme.Spacing.m)
            .frame(height: 54)
            .frame(minWidth: 150)
            .background(background, in: Capsule())
            // Focus = zoom only. Selection = accent fill (see `background`). No ring, no glass.
            .scaleEffect(isFocused && !RVTheme.reduceMotion ? 1.08 : 1.0)
            .animation(RVTheme.Anim.focus, value: isFocused)
            .animation(RVTheme.Anim.focus, value: isSelected)
    }

    private var background: Color {
        if isSelected {
            return RVTheme.Colors.accent
        }
        if isFocused {
            return RVTheme.Colors.focusFill
        }
        return RVTheme.Colors.material
    }
}

struct RVStepperRow: View {
    let systemImage: String?
    let title: String
    let description: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    // Numeric values (e.g. "280 ms") read better monospaced; word values
    // (e.g. "Balanced") should use the regular menu font so they match the rest.
    let usesMonospacedValue: Bool

    init(
        systemImage: String? = nil,
        title: String,
        description: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        usesMonospacedValue: Bool = true,
        formatter: @escaping (Double) -> String
    ) {
        self.systemImage = systemImage
        self.title = title
        self.description = description
        _value = value
        self.range = range
        self.step = step
        self.usesMonospacedValue = usesMonospacedValue
        self.formatter = formatter
    }

    var body: some View {
        RVFocusRow(systemImage: systemImage, title: title, description: description) {
            HStack(spacing: 0) {
                stepVisual(systemName: "chevron.left")
                Text(formatter(value))
                    .font(usesMonospacedValue ? RVTheme.Fonts.monospacedValue : RVTheme.Fonts.body)
                    .foregroundStyle(RVTheme.Colors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 180, height: 54)
                    .background(RVTheme.Colors.material)
                stepVisual(systemName: "chevron.right")
            }
            .background(RVTheme.Colors.material, in: Capsule())
            .clipShape(Capsule())
        }
        .onMoveCommand { direction in
            if direction == .left {
                decrement()
            } else if direction == .right {
                increment()
            }
        }
    }

    private func stepVisual(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(RVTheme.Fonts.caption.weight(.semibold))
            .foregroundStyle(RVTheme.Colors.primaryText)
            .frame(width: 66, height: 54)
            .background(RVTheme.Colors.strongMaterial)
    }

    private func decrement() {
        value = max(range.lowerBound, value - step)
    }

    private func increment() {
        value = min(range.upperBound, value + step)
    }
}

struct RVPillTabBar: View {
    let tabs: [(systemImage: String, title: String)]
    @Binding var selection: Int
    // Owned by the host view (e.g. BrowseModalView) so it can move focus onto the
    // pills programmatically — needed for the two-stage Menu behaviour.
    var focusedTab: FocusState<Int?>.Binding
    @Namespace private var tabFocusNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { index in
                Button {
                    selection = index
                    focusedTab.wrappedValue = index
                } label: {
                    RVPillTabLabel(tab: tabs[index], isSelected: selection == index)
                }
                .buttonStyle(RVRowButtonStyle())   // suppress the tvOS system white focus frame
                .focused(focusedTab, equals: index)
                .prefersDefaultFocus(selection == index, in: tabFocusNamespace)
            }
        }
        .padding(5)
        .background(RVTheme.Colors.panelSurface, in: Capsule())   // solid dark bar, no glass
        .focusScope(tabFocusNamespace)
        .onChange(of: focusedTab.wrappedValue) {
            if let focused = focusedTab.wrappedValue {
                selection = focused
            }
        }
        .onChange(of: selection) {
            guard focusedTab.wrappedValue != selection else { return }
            focusedTab.wrappedValue = selection
        }
    }
}

private struct RVPillTabLabel: View {
    let tab: (systemImage: String, title: String)
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: RVTheme.Spacing.xs) {
            Image(systemName: tab.systemImage)
            Text(tab.title)
        }
        .font(RVTheme.Fonts.caption.weight(isSelected || isFocused ? .semibold : .medium))
        .foregroundStyle(labelColor)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)       // hug the label — no fixed-width slab
        .padding(.horizontal, RVTheme.Spacing.l)
        .frame(height: 74)
        .background(tabBackground, in: Capsule())            // solid fill — no glass bloom / halo
        // Focus = zoom. Selection = accent pill. No white fill, no ring.
        .scaleEffect(isFocused && !RVTheme.reduceMotion ? 1.08 : 1.0)
        .animation(RVTheme.Anim.focus, value: isFocused)
        .animation(RVTheme.Anim.focus, value: isSelected)
    }

    private var labelColor: Color {
        (isSelected || isFocused) ? RVTheme.Colors.primaryText : RVTheme.Colors.mutedText
    }

    private var tabBackground: Color {
        if isSelected {
            return RVTheme.Colors.accent
        }
        if isFocused {
            return RVTheme.Colors.focusFill
        }
        return Color.clear
    }
}
