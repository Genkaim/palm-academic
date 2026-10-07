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

/// The search control that sits beside the tab bar.
///
/// The destinations themselves live in a system `TabView` rather than in a hand-built bar. That is
/// the only way to get the platform's own bottom bar: on iOS 26 it is drawn with the system's
/// Liquid Glass material, and it carries the press, the long-press and the destination-change
/// animations, none of which a custom view can reproduce -- a custom bar can approximate the
/// material, but every one of those behaviours has to be rebuilt by hand and will always be a
/// little behind the real thing.
///
/// Search stays outside that bar. Android can afford a search button on the bar because its bar only
/// exists on the home screen; iOS keeps the bar on every screen, so search has to open where the
/// user already is. Opening it slides the field in over the width the collapsed button occupied and
/// brings a cancel control in at the leading edge; closing runs the same two moves backwards.
struct BarSearchControl: View {
    @Binding var isSearching: Bool
    @Binding var query: String
    var isDark: Bool

    @Namespace private var searchNamespace

    private enum Metric {
        /// A tab bar item's own height, which is also the collapsed width of this button.
        static let collapsed: CGFloat = 49
    }

    /// Matches the Android bar's spring: damping ratio 0.82 at stiffness 440, which for unit mass
    /// is a damping coefficient of `2 * 0.82 * sqrt(440)`.
    private var spring: Animation { .interpolatingSpring(stiffness: 440, damping: 34) }

    private var ink: Color { isDark ? .white : .primary }

    var body: some View {
        // The control occupies the trailing slot. Collapsed it is a 49pt circle; expanded it hands
        // that slot over to the field, which grows leftwards into the row.
        ZStack(alignment: .trailing) {
            if isSearching {
                HStack(spacing: 4) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ink)
                            .frame(width: Metric.collapsed, height: Metric.collapsed)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TabPressStyle())
                    .accessibilityLabel("关闭搜索")

                    NativeSearchField(
                        text: $query,
                        placeholder: "搜索教务功能",
                        isCancelVisible: true,
                        onCancel: { close() }
                    )
                    .frame(height: Metric.collapsed - 8)
                    .matchedGeometryEffect(id: "barSearchField", in: searchNamespace)
                }
                .background(
                    SystemGlassSurface(
                        shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
                        interactive: true
                    ) {
                        Color.clear
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(spring) { isSearching = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(ink)
                        .frame(width: Metric.collapsed, height: Metric.collapsed)
                        .contentShape(Rectangle())
                        .matchedGeometryEffect(id: "barSearchField", in: searchNamespace)
                        .background(
                            SystemGlassSurface(shape: Circle(), interactive: true) {
                                Color.clear
                            }
                        )
                }
                .buttonStyle(TabPressStyle())
                .accessibilityLabel(LiquidTabItem.search.title)
                .accessibilityHint(Text("在当前页面搜索教务功能"))
            }
        }
        .frame(height: Metric.collapsed)
    }

    /// Closing runs the open animation backwards: the field leaves towards the edge it came from
    /// and the button takes its place, which is the same relationship Android's bar has when its
    /// search button collapses back into an icon.
    private func close() {
        withAnimation(spring) {
            isSearching = false
            query = ""
        }
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

    /// The two destinations, matching Android's `HomeDestination`. Search is deliberately not one
    /// of them: it is an action, not a place, and `BarSearchControl` handles it.
    static let home = LiquidTabItem(id: "home", title: "主页", systemImage: "house")
    static let settings = LiquidTabItem(id: "settings", title: "设置", systemImage: "gearshape")
    static let search = LiquidTabItem(id: "search", title: "搜索", systemImage: "magnifyingglass",
                                      selectedSystemImage: "magnifyingglass")
}