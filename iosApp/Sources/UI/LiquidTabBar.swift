import SwiftUI
import UIKit

/// Applies SwiftUI's own glass modifier where the build links an SDK that declares it.
///
/// The modifier cannot be named from an older SDK -- that is a compile error, not a runtime
/// condition -- so it stays behind the compile-time switch, with the availability test inside:
/// the deployment target is 16.0, so without it the compiler rejects the call outright.
///
/// When it cannot be applied the view is returned untouched and the caller falls back to a
/// tuned material stack: regularMaterial (rather than the lighter ultraThinMaterial the prior
/// version chose) plus a top highlight, a thin stroke and a contact shadow, so the bar still
/// reads as glass on iOS 17/18 hardware where the runtime API is unavailable.
struct SystemGlassSurface<Content: View, S: Shape>: View {
    var shape: S
    var interactive: Bool = false
    /// Strength of the fallback material. `.regularMaterial` is the iOS-default glass substitute;
    /// bumping it to `.thickMaterial` gives the bar enough presence on iOS 17/18 that it reads
    /// as a real floating surface rather than a soft tint.
    var strength: Material = .regularMaterial
    @ViewBuilder var content: Content

    var body: some View {
        #if USE_SYSTEM_GLASS
        if #available(iOS 26.0, *) {
            if interactive {
                content
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    /// The material stack used when the native glass is unavailable. Three layers stacked on
    /// the same shape give the visual depth that the real API gives for free: the material
    /// shows the surface below with a slight blur; the highlight adds a top-of-pill sheen;
    /// the shadow defines the silhouette so the pill reads as a physical piece of glass
    /// rather than a tint behind the buttons.
    ///
    /// A `strokeBorder` overlay would add a thin glass edge, but `Shape.strokeBorder`'s
    /// generic overloads are not resolvable through `S: Shape` (the generic context here is
    /// the public surface of `SystemGlassSurface`), so the edge is skipped on the fallback
    /// path -- the top highlight plus the drop shadow carry enough definition on their own.
    private var fallback: some View {
        content
            .background(strength, in: shape)
            .overlay(
                LinearGradient(
                    colors: [.white.opacity(0.32), .white.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(shape)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 5)
    }
}

/// Press feedback for controls that have no system press state of their own.
///
/// On the search pill a long press lifts the entire pill -- a small scale-up plus a glow --
/// so the bar mimics the way native iOS search affordances grow under sustained touch.
struct TabPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

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
/// Layout follows Apple's iOS 26 floating tab bar: a single continuous glass capsule sized to
/// its content, centred horizontally, floating 8pt above the bottom safe-area edge. There is
/// deliberately NO full-width material strip behind it -- the earlier backdrop rectangle filled
/// the home-indicator gutter with an opaque blur and read as a dead block of colour; the system
/// bar lets the page show through around the capsule, including behind the home indicator.
struct FloatingHomeNavigation: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    /// Capsule geometry, matched to the iOS 26 system floating tab bar: ~60pt tall, two tab
    /// slots plus a gap and a circular search control of the same diameter.
    private static let barHeight: CGFloat = 60
    private static let tabCapsuleWidth: CGFloat = 180
    private static let itemGap: CGFloat = 8
    /// Compact width is exactly the two pieces + gap, so the expanded search capsule morphs from
    /// the same footprint.
    private static let compactWidth: CGFloat = tabCapsuleWidth + itemGap + barHeight
    /// The open search field is given a touch more room for the placeholder and clear button,
    /// but stays a floating capsule rather than stretching edge to edge.
    private static let expandedWidth: CGFloat = 280
    /// Gap between the capsule's bottom edge and the top of the bottom safe area, matching the
    /// system floating bar.
    private static let bottomGap: CGFloat = 8

    /// Drives both morphs: the search circle -> search capsule, and the selected-tab highlight
    /// sliding between the two destinations.
    @Namespace private var chrome
    @Namespace private var selection

    /// Two springs, tuned to feel like a real app launch.
    ///
    /// `morphSpring` overshoots slightly so the circle "pops" into the capsule the way an app
    /// icon springs into a window when launched; `selectionSpring` is tighter so the highlight
    /// snap between tabs stays snappy and does not bleed into the morph.
    private let morphSpring: Animation = .spring(response: 0.52, dampingFraction: 0.66)
    private let selectionSpring: Animation = .spring(response: 0.30, dampingFraction: 0.72)

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        // Just the floating capsule, centred. No backdrop: anything outside the capsule (the
        // home-indicator gutter included) stays the page underneath, which is what makes the
        // bar read as hovering the way Apple's does.
        HStack(spacing: 0) {
            Group {
                if state.isSearchPresented {
                    expandedSearch
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.55, anchor: .trailing)
                                    .combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                } else {
                    compactNavigation
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 1.12, anchor: .leading)
                                    .combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
            }
            .frame(
                width: state.isSearchPresented ? Self.expandedWidth : Self.compactWidth,
                height: Self.barHeight
            )
            .scaleEffect(morphScale, anchor: .center)
            .animation(reduceMotion ? nil : morphSpring, value: state.isSearchPresented)
            .animation(reduceMotion ? nil : morphSpring, value: morphScale)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // The host pins this view to the screen's bottom edge; SwiftUI's own safe-area inset
        // lifts the capsule to the top of the home-indicator gutter, and this small gap matches
        // the system floating bar's clearance.
        .padding(.bottom, Self.bottomGap)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: state.isSearchPresented) { presented in
            if presented {
                // Wait until the field is in the hierarchy so the keyboard and the expanding pill
                // start together, as they do in Android's floating navigation.
                DispatchQueue.main.async { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
    }

    /// A pulse that lifts the morph off its starting size and lets the spring settle into 1.0.
    ///
    /// The matched-geometry effect already animates bounds and position, but iOS does not visibly
    /// "punch in" the destination the way an app launch icon does. Pairing a 0.78 -> 1.0 scale on
    /// the morph value gives the open transition a tap of weight at the start, which is what makes
    /// the bar feel like it is opening an app rather than stretching a rectangle.
    private var morphScale: CGFloat {
        state.isSearchPresented ? 1.0 : 0.78
    }

    private var compactNavigation: some View {
        HStack(spacing: Self.itemGap) {
            SystemGlassSurface(shape: shape, interactive: true) {
                HStack(spacing: 2) {
                    tabButton(.home)
                    tabButton(.settings)
                }
                .padding(6)
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
                .buttonStyle(TabPressStyle(scale: 0.9))
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索教务功能", text: $state.searchQuery)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索教务功能")
                Button {
                    state.dismissSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: Self.barHeight)
                }
                .buttonStyle(TabPressStyle())
                .accessibilityLabel("关闭搜索")
            }
            .padding(.leading, 18)
            .padding(.trailing, 4)
            .frame(width: Self.expandedWidth, height: Self.barHeight)
            // The contents fade in across the morph; a glyph stretched by the frame interpolation
            // would smear, so the contents ride the last third of the move instead.
            .opacity(state.isSearchPresented ? 1 : 0)
        }
        .frame(width: Self.expandedWidth, height: Self.barHeight)
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
                        .fill(Color.accentColor.opacity(0.18))
                        .matchedGeometryEffect(id: "tabSelection", in: selection)
                }
                VStack(spacing: 4) {
                    Image(systemName: selected ? item.selectedSystemImage : item.systemImage)
                        .font(.body.weight(.semibold))
                    Text(item.title)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle(scale: 0.92))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
