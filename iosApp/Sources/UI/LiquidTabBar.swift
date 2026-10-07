import SwiftUI
import UIKit

/// Hand-drawn liquid glass bottom bar.
///
/// The Android client ships its own Compose liquid-glass components. On a system that renders
/// Liquid Glass, the same material is available natively, so it is preferred when present and the
/// hand-drawn material stands in everywhere else. Which of the two applies is decided by
/// `SystemGlassSupport.canRenderGlass`, which accounts for the linked SDK as well as the running
/// system.
///
/// Note that a recent system alone does not bring the native look: Apple gates the design on the
/// SDK the app was linked against. An app built with an older SDK keeps the previous system
/// appearance even on iOS 27, so the system version is necessary but not sufficient.
/// The material behind the bar.
///
/// Prefers the system's own glass when the running system has it, and falls back to an
/// `ultraThin` blur otherwise. The choice is made per instance rather than at compile time, so
/// the same binary renders glass on a recent device and blur on an older one.
struct LiquidGlassBackground: UIViewRepresentable {
    var cornerRadius: CGFloat = 32
    var isDark: Bool = false

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = SystemGlassSupport.makeEffect(style: 0)
            ?? UIBlurEffect(style: .systemUltraThinMaterial)
        let view = UIVisualEffectView(effect: effect)
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.overrideUserInterfaceStyle = isDark ? .dark : .light
    }
}

/// The capsule behind the selected tab.
///
/// Real glass where the system provides it, `.ultraThinMaterial` otherwise. The material is
/// resolved by the same helper the bar uses, so both surfaces on this screen agree on which one
/// is in use instead of each deciding separately.
struct LiquidGlassIndicator: View {
    var isActive: Bool
    var isDark: Bool

    var body: some View {
        indicatorBackground
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                (isDark ? Color.white : Color.black).opacity(0.18),
                                (isDark ? Color.white : Color.black).opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .frame(width: 62, height: 46)
            // Only the transform and the opacity are animated. A drop shadow here was the single
            // biggest source of tab-switch jank: it has to re-rasterise its bitmap on every frame
            // of the spring, which the container renderer does not accelerate. Drawing the shade
            // as a static shape behind the capsule keeps the motion down to a pure transform.
            .background(
                Capsule()
                    .fill(Color.black)
                    .opacity(isDark ? 0.3 : 0.12)
                    .blur(radius: 8)
                    .offset(y: 3)
                    .allowsHitTesting(false)
            )
            .scaleEffect(y: isActive ? 1.0 : 0.86)
            .opacity(isActive ? 1.0 : 0.0)
            .animation(.spring(response: 0.34, dampingFraction: 0.68), value: isActive)
    }

    /// The capsule's own fill.
    ///
    /// `isInteractive` is what makes system glass swell and catch the light on touch, which is the
    /// behaviour that reads as glass rather than as a translucent fill. It needs children to
    /// respond to, so it is only requested here, where the tab's icon and label sit above it.
    @ViewBuilder
    private var indicatorBackground: some View {
        if let glass = SystemGlassSupport.makeGlassView(
            style: 0,
            interactive: true,
            cornerRadius: 23
        ) {
            glass
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
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

    static let home = LiquidTabItem(id: "home", title: "首页", systemImage: "house")
    static let quick = LiquidTabItem(id: "quick", title: "快捷", systemImage: "square.grid.2x2")
    static let notices = LiquidTabItem(id: "notices", title: "记录", systemImage: "clock.arrow.circlepath")
    static let settings = LiquidTabItem(id: "settings", title: "设置", systemImage: "gearshape")
}

struct LiquidTabBar: View {
    let items: [LiquidTabItem]
    @Binding var selection: LiquidTabItem
    let isDark: Bool

    var body: some View {
        if systemDrawsSelectionWell {
            applySystemGlass(to: barContent.overlay(rimStroke))
        } else {
            // No modifier to call, but the runtime may still produce the material.
            // `LiquidGlassBackground` asks for it and falls back to a blur on its own, so the bar
            // gets real glass on a recent device without any compile-time coupling.
            barContent
                .background(LiquidGlassBackground(cornerRadius: 30, isDark: isDark))
                .overlay(rimStroke)
        }
    }

    /// Applies SwiftUI's own glass modifier.
    ///
    /// Only reachable on a build that links an SDK declaring the iOS 26 API. The modifier cannot be
    /// named from an older SDK -- that is a compile error, not a runtime condition -- so it stays
    /// behind the compile-time switch.
    ///
    /// The availability test inside is required rather than defensive: the deployment target is
    /// 16.0, so without it the compiler rejects the call on the grounds that the modifier is only
    /// available from iOS 26. `systemDrawsSelectionWell` already established at runtime that the
    /// device qualifies; this states it in the form the compiler can check.
    @ViewBuilder
    private func applySystemGlass<V: View>(to view: V) -> some View {
        #if USE_SYSTEM_GLASS
        if #available(iOS 26.0, *) {
            view.glassEffect(.regular, in: .capsule)
        } else {
            view
        }
        #else
        view
        #endif
    }

    /// The hairline along the bar's rim.
    ///
    /// Kept on both paths: neither `UIGlassEffect` nor SwiftUI's `glassEffect` draws an outline,
    /// and without one the bar's edge dissolves into the content behind it. A static stroke is
    /// rasterised once, so unlike a shadow it costs nothing per frame.
    private var rimStroke: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        (isDark ? Color.white : Color.black).opacity(0.22),
                        (isDark ? Color.white : Color.black).opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var barContent: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tabButton(item)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        // Same reasoning as the indicator: the bar's own drop shadow is a static shape sitting
        // behind the content, so it costs one rasterisation rather than one per frame.
        .background(
            Capsule()
                .fill(Color.black)
                .opacity(isDark ? 0.4 : 0.14)
                .blur(radius: 18)
                .offset(y: 8)
                .allowsHitTesting(false)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var accent: Color {
        isDark ? Color(red: 0.55, green: 0.78, blue: 1.0) : Color(red: 0.16, green: 0.44, blue: 0.85)
    }

    @ViewBuilder
    private func tabButton(_ item: LiquidTabItem) -> some View {
        let isActive = item == selection
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
                selection = item
            }
        } label: {
            ZStack {
                if isActive {
                    indicator(isActive: true)
                }
                VStack(spacing: 3) {
                    Image(systemName: isActive ? item.selectedSystemImage : item.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                    Text(item.title)
                        .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                }
                .foregroundStyle(isActive ? accent : (isDark ? Color.white.opacity(0.6) : Color.secondary))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    /// Whether the system draws the selection well itself.
    ///
    /// True only when the modifier can be named *and* the running system renders it. On a build
    /// that has the API but runs on an older device, the bar falls back to the hand-drawn
    /// material and this must stay false, or the selected item would have no indicator at all.
    private var systemDrawsSelectionWell: Bool {
        SystemGlassSupport.hasNativeGlassAPI && SystemGlassSupport.isLiquidGlassOS
    }

    @ViewBuilder
    private func indicator(isActive: Bool) -> some View {
        // The system glass draws its own selection well, but only in the same case the bar itself
        // does. Everywhere else the runtime path renders the bar's material yet no well, so the
        // hand-drawn capsule stays responsible. Gating this on the system version rather than on
        // the SDK would leave older devices with neither.
        if systemDrawsSelectionWell {
            Color.clear.frame(width: 62, height: 46)
        } else {
            LiquidGlassIndicator(isActive: isActive, isDark: isDark)
        }
    }
}

/// Glass card used for content blocks, matching the Android `PortalGlassComponents` surface.
///
/// The fill is resolved through the same helper as the tab bar, so a card and the bar around it
/// are made of the same material on a given device. Cards are not interactive: they are content
/// surfaces, and requesting the touch response from them would make scrolling feel like pressing.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var isDark: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                (isDark ? Color.white : Color.black).opacity(0.16),
                                (isDark ? Color.white : Color.black).opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
            )
            // Static background layer instead of `.shadow`. These cards get rebuilt while their
            // content scrolls, and a modifier-driven shadow is re-rasterised on each rebuild.
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                    .opacity(isDark ? 0.28 : 0.07)
                    .blur(radius: 12)
                    .offset(y: 5)
                    .allowsHitTesting(false)
            )
    }

    @ViewBuilder
    private var cardFill: some View {
        if let glass = SystemGlassSupport.makeGlassView(cornerRadius: cornerRadius) {
            glass
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.72))
        }
    }
}
