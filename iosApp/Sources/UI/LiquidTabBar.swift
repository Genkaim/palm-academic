import SwiftUI
import UIKit

/// Applies SwiftUI's own glass modifier where the build links an SDK that declares it.
///
/// The modifier cannot be named from an older SDK -- that is a compile error, not a runtime
/// condition -- so it stays behind the compile-time switch, with the availability test inside:
/// the deployment target is 16.0, so without it the compiler rejects the call outright.
///
/// When it cannot be applied the view is returned untouched and the caller falls back to a system
/// material, which is also what a build without the API gets on a recent device.
///
/// The shape is generic rather than an existential because `glassEffect(_:in:)` and
/// `background(_:in:)` both want a concrete `Shape`; handing them an `any Shape` does not compile.
struct SystemGlassSurface<Content: View, S: Shape>: View {
    var shape: S
    var interactive: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        #if USE_SYSTEM_GLASS
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    /// The material used when the native glass is unavailable. `.ultraThinMaterial` is itself a
    /// system material, so it keeps tracking the appearance instead of being a hand-mixed colour.
    private var fallback: some View {
        content.background(.ultraThinMaterial, in: shape)
    }
}

/// Port of the Android `FloatingHomeNavigation`: two tabs and a search button that share one row.
///
/// The numbers below are the Android ones. What makes the layout non-obvious is that the two
/// pieces overlap rather than sit side by side once search opens. Collapsed, the row is
/// `210 + 10 + 64 = 284` wide and the search button occupies the row's trailing spacer. Expanded,
/// the tabs grow to the full 284 and the search field grows to 284 as well, so the field covers
/// them completely -- which is why the trailing spacer animates to zero and the field's own centre
/// offset animates back to zero at the same time.
struct LiquidBottomBar: View {
    let isDark: Bool
    @Binding var selection: LiquidTabItem
    @Binding var searchExpanded: Bool
    @Binding var query: String
    var onCloseSearch: () -> Void

    private enum Metric {
        static let tabsCollapsed: CGFloat = 210
        static let tabsExpanded: CGFloat = 284
        static let searchCollapsed: CGFloat = 64
        static let searchExpandedWidth: CGFloat = 284
        static let gapCollapsed: CGFloat = 10
        static let slotCollapsed: CGFloat = 64
        /// How far the collapsed field sits right of centre, which lands it on the row's spacer.
        static let collapsedOffset: CGFloat = 110
        static let barHeight: CGFloat = 64
    }

    private var tabsWidth: CGFloat {
        searchExpanded ? Metric.tabsExpanded : Metric.tabsCollapsed
    }

    private var searchWidth: CGFloat {
        searchExpanded ? Metric.searchExpandedWidth : Metric.searchCollapsed
    }

    private var gap: CGFloat { searchExpanded ? 0 : Metric.gapCollapsed }
    private var slotWidth: CGFloat { searchExpanded ? 0 : Metric.slotCollapsed }
    private var collapsedOffset: CGFloat { searchExpanded ? 0 : Metric.collapsedOffset }

    /// Matches the Android spring: damping ratio 0.82 at stiffness 440, which for unit mass is a
    /// damping coefficient of `2 * 0.82 * sqrt(440)`.
    private var spring: Animation { .interpolatingSpring(stiffness: 440, damping: 34) }

    var body: some View {
        ZStack(alignment: .bottom) {
            tabRow
            searchLayer
                .frame(width: searchWidth, height: Metric.barHeight)
                .frame(maxWidth: .infinity)
                .offset(x: collapsedOffset)
        }
        .animation(spring, value: searchExpanded)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var tabRow: some View {
        HStack(spacing: gap) {
            tabBar
                .frame(width: tabsWidth)
            Color.clear.frame(width: slotWidth, height: Metric.barHeight)
        }
        .frame(maxWidth: .infinity)
    }

    private var tabBar: some View {
        SystemGlassSurface(shape: Capsule()) {
            HStack(spacing: 0) {
                tabButton(.home)
                tabButton(.settings)
            }
            .padding(4)
        }
        .frame(height: Metric.barHeight)
    }

    private var searchLayer: some View {
        SystemGlassSurface(shape: Capsule(), interactive: searchExpanded) {
            Group {
                if searchExpanded {
                    expandedSearchField
                } else {
                    collapsedSearchButton
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Metric.barHeight)
    }

    private var collapsedSearchButton: some View {
        Button {
            searchExpanded = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(ink)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("搜索")
    }

    private var expandedSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索教务功能", text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }

            Button {
                onCloseSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭搜索")
        }
        .padding(.horizontal, 18)
    }

    private var ink: Color {
        isDark ? Color.white : Color.primary
    }

    private func tabButton(_ item: LiquidTabItem) -> some View {
        let isActive = item == selection
        return Button {
            withAnimation(spring) { selection = item }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isActive ? item.selectedSystemImage : item.systemImage)
                    .font(.system(size: 21, weight: .regular))
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            // The selected well. On a system that draws the glass itself the tint is left to it,
            // which is the same rule SystemGlassSupport.hasNativeGlassAPI encodes.
            Capsule()
                .fill(isActive ? Color.primary.opacity(isDark ? 0.16 : 0.08) : .clear)
        )
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }
}

struct LiquidTabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let selectedSystemImage: String

    init(id: String, title: String, systemImage: String, selectedSystemImage: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.selectedSystemImage = selectedSystemImage ?? "\(systemImage).fill"
    }

    /// Matches the Android tab set: `主页` and `设置` only. The Android client has no separate
    /// quick-entry or history tab -- quick entries are the grid on the home screen, search is the
    /// trailing button, and the check log is reached from Settings.
    static let home = LiquidTabItem(id: "home", title: "主页", systemImage: "house")
    static let settings = LiquidTabItem(id: "settings", title: "设置", systemImage: "gearshape")
}

/// Glass card used for content blocks, matching the Android `PortalGlassComponents` surface.
///
/// The fill is resolved through the same helper as the bar, so a card and the bar around it are
/// made of the same material on a given device. Cards are not interactive: they are content
/// surfaces, and requesting the touch response from them would make scrolling feel like pressing.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var isDark: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.72))
            )
    }
}
