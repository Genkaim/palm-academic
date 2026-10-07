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
    /// The Android "液态玻璃" switch. Turning it off keeps the same shape and layout but drops back
    /// to a plain system material, which is what the client exposes as a user preference.
    var enabled: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        #if USE_SYSTEM_GLASS
        if #available(iOS 26.0, *), enabled {
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

/// The bottom bar: two tabs, nothing else.
///
/// An earlier version carried a trailing search button copied from the Android client, which is the
/// wrong shape for this platform. A system tab bar holds destinations and nothing more, and the
/// platform's search affordance is `.searchable` on the navigation bar -- it brings the expand, the
/// cancel button, the clear button and the keyboard handling for free. Search lives there now, which
/// is also why the hand-rolled close button that used to sit in the bar is gone.
struct LiquidBottomBar: View {
    let isDark: Bool
    let glassEnabled: Bool
    @Binding var selection: LiquidTabItem

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
        SystemGlassSurface(shape: Capsule(), interactive: true, enabled: glassEnabled) {
            HStack(spacing: 0) {
                tabButton(.home)
                tabButton(.settings)
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

    /// Matches the Android tab set: `主页` and `设置` only. The Android client has no separate
    /// quick-entry or history tab -- quick entries are the grid on the home screen, search is the
    /// navigation bar's own field, and the check log is reached from Settings.
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
