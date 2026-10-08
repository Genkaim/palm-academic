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
/// turns that target into the same bottom-anchored search surface instead of inserting a second
/// field at the top of the list. SwiftUI's keyboard safe area carries the expanded surface above
/// the keyboard; its spring only animates the shape and never fights the system keyboard motion.
struct FloatingHomeNavigation: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    private let shape = Capsule(style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if state.isSearchPresented {
                    expandedSearch
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    compactNavigation
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84), value: state.isSearchPresented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
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
                .frame(width: 208, height: 64)
            }

            SystemGlassSurface(shape: Circle(), interactive: true) {
                Button {
                    state.presentSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(TabPressStyle())
                .accessibilityLabel("搜索教务功能")
            }
            .frame(width: 64, height: 64)
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
            .frame(maxWidth: 360)
            .frame(height: 64)
        }
    }

    private func tabButton(_ item: LiquidTabItem) -> some View {
        let selected = state.selectedTab == item
        return Button {
            if state.isSearchPresented { state.dismissSearch() }
            if reduceMotion {
                state.selectedTab = item
            } else {
                withAnimation(.easeInOut(duration: 0.24)) { state.selectedTab = item }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: selected ? item.selectedSystemImage : item.systemImage)
                    .font(.body.weight(.semibold))
                Text(item.title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
        }
        .buttonStyle(TabPressStyle(scale: 0.96))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
