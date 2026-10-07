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

/// The bottom bar: two destinations plus the search field, which expands in place.
///
/// Search is here rather than in a navigation bar for two reasons that are both about this
/// platform. First, the bar is present on every screen -- Android's is not, which is why Android
/// can hide search behind "go back to the home tab first" -- so search has to work where the user
/// already is, without switching destinations under them. Second, once expanded it *is* the search
/// field: the bar grows sideways into a `UISearchTextField` with a 取消 button beside it, which is
/// the same relationship the system search bar has with a navigation bar. Making search a third
/// destination instead would have been the Android shape, and this is not Android.
struct LiquidBottomBar: View {
    let isDark: Bool
    @Binding var selection: LiquidTabItem
    /// Whether the bar is currently showing the search field instead of the destinations.
    @Binding var isSearching: Bool
    @Binding var searchQuery: String

    @Namespace private var indicatorNamespace

    private enum Metric {
        static let height: CGFloat = 64
        static let horizontalPadding: CGFloat = 16
        static let bottomPadding: CGFloat = 8
    }

    private var ink: Color {
        isDark ? Color.white : Color.primary
    }

    /// Matches the Android spring: damping ratio 0.82 at stiffness 440, which for unit mass is a
    /// damping coefficient of `2 * 0.82 * sqrt(440)`.
    private var spring: Animation { .interpolatingSpring(stiffness: 440, damping: 34) }

    var body: some View {
        SystemGlassSurface(shape: Capsule(), interactive: true) {
            HStack(spacing: 0) {
                if isSearching {
                    searchContents
                } else {
                    destinations
                }
            }
            .padding(4)
        }
        .frame(height: Metric.height)
        .padding(.horizontal, Metric.horizontalPadding)
        .padding(.bottom, Metric.bottomPadding)
        .onChange(of: selection) { _ in
            // The system selector tick. `sensoryFeedback` would be the modern spelling but it is
            // iOS 17+, and the deployment target is 16.0.
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var destinations: some View {
        HStack(spacing: 0) {
            tabButton(.home)
            searchButton
            tabButton(.settings)
        }
    }

    /// The expanded state. The field takes what the destinations used, and 取消 sits at the trailing
    /// edge, so the layout is the same width and the same capsule -- only the contents change.
    private var searchContents: some View {
        HStack(spacing: 6) {
            NativeSearchField(
                text: $searchQuery,
                placeholder: "搜索教务功能",
                isCancelVisible: true,
                onCancel: {
                    withAnimation(spring) { isSearching = false }
                }
            )
            .frame(height: 44)

            Button {
                withAnimation(spring) {
                    isSearching = false
                    searchQuery = ""
                }
            } label: {
                Text("取消")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(TabPressStyle(scale: 0.94))
            .frame(height: 44)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    /// The search affordance while collapsed. It is a button and not a third destination: tapping it
    /// raises the field without moving the user off the screen they are on.
    private var searchButton: some View {
        Button {
            withAnimation(spring) { isSearching = true }
        } label: {
            ZStack {
                VStack(spacing: 2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 21, weight: .regular))
                    Text(LiquidTabItem.search.title)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .accessibilityLabel(Text(LiquidTabItem.search.title))
        .accessibilityHint(Text("在当前页面搜索教务功能"))
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
                    Capsule()
                        .fill(Color.primary.opacity(isDark ? 0.18 : 0.09))
                        .matchedGeometryEffect(id: "tabIndicator", in: indicatorNamespace)
                }
                VStack(spacing: 2) {
                    Image(systemName: isActive ? item.selectedSystemImage : item.systemImage)
                        .font(.system(size: 21, weight: .regular))
                    Text(item.title)
                        .font(.system(size: 10, weight: .medium))
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

/// Glass card used for content blocks, matching the Android `PortalGlassComponents` surface.
///
/// The fill is resolved through the same semantic colour the bar uses, so a card and the bar around
/// it are made of the same material on a given device. Cards are not interactive: they are content
/// surfaces, and requesting the touch response from them would make scrolling feel like pressing.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PortalPalette.surface)
            )
    }
}