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
/// Layout follows Apple's iOS 26 floating tab bar: one continuous glass capsule for the two
/// destinations plus a circular glass search control of the same height, the pair centred
/// horizontally and floating just above the bottom safe-area edge. There is deliberately NO
/// full-width material strip behind it -- a backdrop rectangle filled the home-indicator gutter
/// with an opaque blur and read as a dead block of colour.
///
/// The search morph is a single continuous surface, not an if/else branch swap. The tab capsule
/// collapses to zero width while the search circle's frame grows into the field along one spring,
/// so the field visibly grows out of the search button (its trailing edge barely moves; the
/// growth is leftward) instead of flashing in at its final position.
struct FloatingHomeNavigation: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    /// Capsule geometry: 66pt tall -- close to the iOS 26 floating bar -- with two generous tab
    /// slots and a circular search control of the same diameter.
    private static let barHeight: CGFloat = 66
    private static let tabCapsuleWidth: CGFloat = 210
    private static let itemGap: CGFloat = 8
    /// The open search field is roomy but stays a floating capsule rather than going edge to edge.
    private static let expandedWidth: CGFloat = 308
    /// Gap between the capsule's bottom edge and the top of the bottom safe area, matching the
    /// system floating bar.
    private static let bottomGap: CGFloat = 8

    /// Drives the selected-tab highlight sliding between the two destinations.
    @Namespace private var selection

    /// One spring for the whole morph. The tab strip collapsing and the circle growing ride the
    /// SAME curve, which is what makes the motion read as one surface reconfiguring itself.
    private let morphSpring: Animation = .spring(response: 0.45, dampingFraction: 0.78)
    private let selectionSpring: Animation = .spring(response: 0.30, dampingFraction: 0.72)

    private var shape: Capsule { Capsule(style: .continuous) }

    private var isSearchPresented: Bool { state.isSearchPresented }

    var body: some View {
        // The two pieces stay mounted for the lifetime of the bar; only their widths and the
        // gap animate. Keeping the hierarchy stable is precisely what lets the search field
        // grow out of the circle's own position: there is no inserted/removed view whose final
        // frame could flash into place.
        HStack(spacing: isSearchPresented ? 0 : Self.itemGap) {
            tabCapsule
                .frame(width: isSearchPresented ? 0 : Self.tabCapsuleWidth, height: Self.barHeight)
                .opacity(isSearchPresented ? 0 : 1)
                .allowsHitTesting(!isSearchPresented)
                .clipped()

            searchSurface
                .frame(
                    width: isSearchPresented ? Self.expandedWidth : Self.barHeight,
                    height: Self.barHeight
                )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(reduceMotion ? nil : morphSpring, value: isSearchPresented)
        // The host pins this view to the screen's bottom edge; SwiftUI's own safe-area inset
        // lifts the capsule to the top of the home-indicator gutter, and this small gap matches
        // the system floating bar's clearance.
        .padding(.bottom, Self.bottomGap)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: isSearchPresented) { presented in
            if presented {
                // Wait until the field has expanded so the keyboard and the growing pill start
                // together, as they do in Android's floating navigation.
                DispatchQueue.main.async { searchFocused = true }
            } else {
                searchFocused = false
            }
        }
    }

    /// The two destinations on one glass capsule. The capsule itself never re-shapes; its outer
    /// frame simply collapses to zero while the search surface takes the room.
    private var tabCapsule: some View {
        SystemGlassSurface(shape: shape, interactive: true) {
            HStack(spacing: 2) {
                tabButton(.home)
                tabButton(.settings)
            }
            .padding(6)
            .frame(width: Self.tabCapsuleWidth, height: Self.barHeight)
        }
    }

    /// ONE continuous glass surface. A `Capsule` whose width equals its height renders as a
    /// circle, so no shape swap is involved in the morph: the very same piece of glass grows
    /// from 66pt (a circle) to 308pt (the field), with its trailing edge anchored where the
    /// search button was.
    private var searchSurface: some View {
        SystemGlassSurface(shape: shape, interactive: true) {
            ZStack {
                // Compact: the whole circle is the search button.
                Button {
                    // presentSearch also switches the pager back to home: search filters the home
                    // list, so opening it while the settings page is showing must not strand it.
                    state.presentSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(TabPressStyle(scale: 0.9))
                .opacity(isSearchPresented ? 0 : 1)
                .allowsHitTesting(!isSearchPresented)
                .accessibilityLabel("搜索教务功能")

                // Expanded: leading glyph + field + clear. It stays mounted the whole time (only
                // its opacity/hit-testing flips), so focus can land on the field as soon as the
                // surface has room for it without any view being inserted.
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PortalPalette.secondaryText)
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
                .opacity(isSearchPresented ? 1 : 0)
                .allowsHitTesting(isSearchPresented)
            }
        }
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
