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

/// Press feedback for the bar's controls.
///
/// `.buttonStyle(.plain)` has no press state at all, so every control in the bar felt dead: the
/// finger went down and nothing acknowledged it. The system tab bar compresses and springs back,
/// which is what this reproduces.
struct TabPressStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// The bottom bar.
///
/// Search is a **separate button at the edge**, not a third destination sitting beside the other
/// two. Android's bar carries a search action off to one side, and it can, because Android's bar
/// only exists on the home screen. On iOS the bar is present on every screen, so the search action
/// here is deliberately *not* a destination: it expands the bar in place into a
/// `UISearchTextField` with a 取消 button, and the results float above the bar. Tapping search
/// therefore never moves the user off the page they are on.
///
/// Sizes follow Apple's own tab bar: 49pt of content, a 25pt glyph, a 10pt label. An earlier
/// version used a 64pt capsule with 21pt glyphs, which is neither the system metric nor the
/// Android one, and read as two unrelated controls rather than a bar.
struct LiquidBottomBar: View {
    let isDark: Bool
    @Binding var selection: LiquidTabItem
    /// Whether the bar is currently showing the search field instead of the destinations.
    @Binding var isSearching: Bool
    @Binding var searchQuery: String

    @Namespace private var indicatorNamespace

    private enum Metric {
        /// Apple's tab bar content height, excluding the home-indicator safe area.
        static let contentHeight: CGFloat = 49
        static let horizontalPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 6
        static let glyphSize: CGFloat = 25
        static let labelSize: CGFloat = 10
        static let searchButtonSize: CGFloat = 49
    }

    private var ink: Color {
        isDark ? Color.white : Color.primary
    }

    /// Matches the Android spring: damping ratio 0.82 at stiffness 440, which for unit mass is a
    /// damping coefficient of `2 * 0.82 * sqrt(440)`.
    private var spring: Animation { .interpolatingSpring(stiffness: 440, damping: 34) }

    var body: some View {
        HStack(spacing: 8) {
            // The destinations keep their own glass capsule, so the bar still reads as one object
            // while the search action is visibly a separate control.
            SystemGlassSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true) {
                HStack(spacing: 0) {
                    if isSearching {
                        searchField
                    } else {
                        tabButton(.home)
                        tabButton(.settings)
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: Metric.contentHeight)
            }
            .frame(maxWidth: .infinity)

            searchButton
        }
        .padding(.horizontal, Metric.horizontalPadding)
        .padding(.bottom, Metric.bottomPadding)
        .onChange(of: selection) { _ in
            // The system selector tick. `sensoryFeedback` would be the modern spelling but it is
            // iOS 17+, and the deployment target is 16.0.
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// The expanded state. The field takes the width the destinations used and the cancel button
    /// sits at its trailing edge, so only the contents change -- not the capsule, and not the
    /// separate search button on the right.
    private var searchField: some View {
        HStack(spacing: 4) {
            NativeSearchField(
                text: $searchQuery,
                placeholder: "搜索教务功能",
                isCancelVisible: true,
                onCancel: {
                    withAnimation(spring) { isSearching = false }
                }
            )
            .frame(height: 40)

            Button {
                withAnimation(spring) {
                    isSearching = false
                    searchQuery = ""
                }
            } label: {
                Text("取消")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 40)
            }
            .buttonStyle(TabPressStyle(scale: 0.94))
            .transition(.opacity)
        }
        .padding(.leading, 8)
    }

    /// The edge button. It is always present: while search is open it becomes the cancel action,
    /// which is where a user's finger already is, rather than adding a second way out.
    private var searchButton: some View {
        Button {
            withAnimation(spring) {
                if isSearching {
                    isSearching = false
                    searchQuery = ""
                } else {
                    isSearching = true
                }
            }
        } label: {
            ZStack {
                if isSearching {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .regular))
                }
            }
            .foregroundStyle(ink)
            .frame(width: Metric.searchButtonSize, height: Metric.searchButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .background(
            SystemGlassSurface(shape: Circle(), interactive: true) {
                Color.clear.frame(width: Metric.searchButtonSize, height: Metric.searchButtonSize)
            }
        )
        .accessibilityLabel(Text(isSearching ? "关闭搜索" : LiquidTabItem.search.title))
        .accessibilityHint(Text(isSearching ? "收起搜索框" : "在当前页面搜索教务功能"))
    }

    private func tabButton(_ item: LiquidTabItem) -> some View {
        let isActive = item == selection
        return Button {
            withAnimation(spring) { selection = item }
        } label: {
            ZStack {
                // The selection well travels between tabs rather than cross-fading in place, which
                // is what `matchedGeometryEffect` buys over giving each tab its own background.
                if isActive {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(isDark ? 0.18 : 0.09))
                        .matchedGeometryEffect(id: "tabIndicator", in: indicatorNamespace)
                }
                VStack(spacing: 1) {
                    Image(systemName: isActive ? item.selectedSystemImage : item.systemImage)
                        .font(.system(size: Metric.glyphSize, weight: .regular))
                    Text(item.title)
                        .font(.system(size: Metric.labelSize, weight: .medium))
                }
                .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
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

    /// Matches the Android tab set: `主页` and `设置` only, plus the search field that expands out
    /// of the bar rather than occupying a slot. The search item is never a selection, so it is not
    /// in this list -- `MainShellView` reads it by hand.
    static let home = LiquidTabItem(id: "home", title: "主页", systemImage: "house")
    static let settings = LiquidTabItem(id: "settings", title: "设置", systemImage: "gearshape")
    static let search = LiquidTabItem(id: "search", title: "搜索", systemImage: "magnifyingglass",
                                      selectedSystemImage: "magnifyingglass")
}
