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

/// Press feedback for controls that have no system press state of their own.
struct TabPressStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
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

    /// The two destinations, matching Android's `HomeDestination`. Search is a transient control
    /// in the floating navigation, not a destination.
    static let home = LiquidTabItem(id: "home", title: "主页", systemImage: "house")
    static let settings = LiquidTabItem(id: "settings", title: "设置", systemImage: "gearshape")
}

/// iOS counterpart of Android's `FloatingHomeNavigation`.
///
/// The compact state exposes the two destinations and a 44pt-plus search target. Tapping search
/// morphs that circular glass target IN PLACE into a full-width search capsule exactly as wide as
/// the whole bar (rather than sliding a new surface in from the trailing edge): a matched-geometry
/// move grows the circle's frame to the bar's width on a spring, while the field contents fade in.
/// The bar is lifted above the keyboard by its UIKit shell (`MainShellViewController`).
struct FloatingHomeNavigation: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    /// Total width of the compact bar (tab capsule + gap + search circle). The expanded capsule
    /// grows to this exact width, so open and closed states occupy the same footprint.
    private static let barWidth: CGFloat = 282
    private static let barHeight: CGFloat = 64
    private static let tabCapsuleWidth: CGFloat = 208

    /// Drives both morphs: the search circle -> search capsule, and the selected-tab highlight
    /// sliding between the two destinations.
    @Namespace private var chrome
    @Namespace private var selection

    private let morphSpring: Animation = .spring(response: 0.38, dampingFraction: 0.82)
    private let selectionSpring: Animation = .spring(response: 0.30, dampingFraction: 0.72)

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        // Leading aligned, matching the previous free-sized bar: the 282pt chrome stays at the
        // leading 16pt inset instead of drifting to the centre on wide screens.
        HStack(spacing: 0) {
            Group {
                if state.isSearchPresented {
                    expandedSearch
                        .transition(.identity)
                } else {
                    compactNavigation
                        .transition(.identity)
                }
            }
            .frame(width: Self.barWidth, height: Self.barHeight)
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : morphSpring, value: state.isSearchPresented)
        // The shell lifts this host for the keyboard itself; SwiftUI must not ALSO shrink the bar
        // for the keyboard safe area (that doubled the motion).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onChange(of: state.isSearchPresented) { presented in
            if presented {
                // Waiting until the field is in the hierarchy lets the keyboard and the expanding
                // pill start together, as they do in Android's floating navigation.
                DispatchQueue.main.async { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
    }

    private var compactNavigation: some View {
        HStack(spacing: 10) {
            SystemGlassSurface(shape: shape, interactive: true) {
                HStack(spacing: 2) {
                    tabButton(.home)
                    tabButton(.settings)
                }
                .padding(4)
                .frame(width: Self.tabCapsuleWidth, height: Self.barHeight)
            }
            // Fades and shrinks away while the search circle grows into the field, so the open
            // motion reads as the tab strip giving the search the room.
            .opacity(state.isSearchPresented ? 0 : 1)

            SystemGlassSurface(shape: Circle(), interactive: true) {
                Button {
                    // presentSearch also switches the pager back to home: search filters the home
                    // list, so opening it while the settings page is showing must not strand it.
                    state.presentSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .frame(width: Self.barHeight, height: Self.barHeight)
                }
                .buttonStyle(TabPressStyle())
                .accessibilityLabel("搜索教务功能")
            }
            .frame(width: Self.barHeight, height: Self.barHeight)
            // Grows this circle's frame straight into the expanded capsule's frame.
            .matchedGeometryEffect(id: "searchSurface", in: chrome)
        }
    }

    private var expandedSearch: some View {
        SystemGlassSurface(shape: shape, interactive: true) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索教务功能", text: $state.searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索教务功能")
                Button {
                    state.dismissSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TabPressStyle())
                .accessibilityLabel("关闭搜索")
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(width: Self.barWidth, height: Self.barHeight)
            // The contents fade in across the morph; a glyph stretched by the frame interpolation
            // would smear, so the contents ride the last third of the move instead.
            .opacity(state.isSearchPresented ? 1 : 0)
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
        .matchedGeometryEffect(id: "searchSurface", in: chrome)
    }

    private func tabButton(_ item: LiquidTabItem) -> some View {
        let selected = state.selectedTab == item
        return Button {
            if state.isSearchPresented { state.dismissSearch() }
            withAnimation(selectionSpring) { state.selectedTab = item }
        } label: {
            ZStack {
                // One sliding highlight instead of two backgrounds toggling, so changing tabs
                // moves a single piece of glass-tinted fill across the capsule.
                if selected {
                    shape
                        .fill(Color.accentColor.opacity(0.14))
                        .matchedGeometryEffect(id: "tabSelection", in: selection)
                }
                VStack(spacing: 3) {
                    Image(systemName: selected ? item.selectedSystemImage : item.systemImage)
                        .font(.body.weight(.semibold))
                    Text(item.title)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TabPressStyle(scale: 0.94))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
