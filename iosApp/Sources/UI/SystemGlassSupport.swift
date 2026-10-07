import SwiftUI
import UIKit

/// Decides where the glass in this app comes from.
///
/// There are two independent capabilities, and conflating them is what made an earlier version of
/// this file give wrong answers:
///
/// 1. Whether the *system* renders Liquid Glass. Apple keys this to the SDK the app was linked
///    against, not to the OS it runs on: an app built with an older SDK keeps the previous design
///    on a newer system, including on iOS 27. So running on a recent device is not sufficient,
///    and checking the OS version alone would promise glass that never appears.
///
/// 2. Whether the *runtime* is recent enough to have the glass classes at all. This is what
///    `UIDevice` reports, and it is the only part of the question a device can answer.
///
/// `canRenderGlass` is the single question callers should ask. How it is answered changes with the
/// SDK, and callers do not have to know:
///
/// - Built against an SDK that declares the iOS 26 API: SwiftUI's own `glassEffect` is used.
/// - Built against an older SDK, running on iOS 26 or later: `UIGlassEffect` is constructed through
///   the Objective-C runtime. It is an ordinary class, so it can be created without the SDK
///   declaring it, and this build is the case that currently applies.
/// - Otherwise: no glass, and callers use their own material.
enum SystemGlassSupport {
    /// True when the SDK this was compiled against declares the iOS 26 API surface.
    ///
    /// Resolved at compile time on purpose. Naming `glassEffect` from a build against an older SDK
    /// is a compile error rather than a runtime problem, and an `#if` inside a function body would
    /// not help because the unused branch is still type checked. The build therefore defines
    /// `USE_SYSTEM_GLASS` when it links an SDK that has the API, and this stays a constant.
    static var hasNativeGlassAPI: Bool {
        #if USE_SYSTEM_GLASS
        return true
        #else
        return false
        #endif
    }

    /// The running system's major version, e.g. 27 for iOS 27.
    ///
    /// Read from `UIDevice` rather than through `#available`. The availability path bottoms out in
    /// `__isPlatformVersionAtLeast`, which on this cross-compile route is answered by the local
    /// stub in `scripts/platform-version-stub.c`; the stub is a strong definition that wins over
    /// the one dyld would supply, so it has to be correct for `#available` to mean anything here.
    /// Parsing the version string sidesteps that dependency entirely.
    static var systemMajorVersion: Int {
        let raw = UIDevice.current.systemVersion
        guard let separator = raw.firstIndex(where: { $0 == "." }) else {
            return Int(raw) ?? 0
        }
        return Int(raw[raw.startIndex..<separator]) ?? 0
    }

    /// Whether the device is running a system that ships the Liquid Glass classes.
    ///
    /// The first release carrying them is iOS 26, so any later major version qualifies.
    static var isLiquidGlassOS: Bool {
        systemMajorVersion >= 26
    }

    /// The single question callers ask: should this build draw real glass?
    static var canRenderGlass: Bool {
        hasNativeGlassAPI || isLiquidGlassOS
    }

    // MARK: - Runtime construction

    /// Builds a `UIVisualEffect` for the given parameters, or nil when the running system cannot
    /// produce glass and the caller should fall back to its own material.
    ///
    /// `style` mirrors `UIGlassEffect.Style`: 0 is the adaptive frosted material used for chrome,
    /// 1 is the lighter refractive one intended for media behind it.
    ///
    /// Properties are written through KVC rather than through a typed interface, because the old
    /// SDK has no `UIGlassEffect` declaration to compile against. Every value is optional and a
    /// failure to set one is not fatal -- it only costs the tint or the interactive response.
    static func makeEffect(style: Int = 0, tint: UIColor? = nil, interactive: Bool = false)
        -> UIVisualEffect?
    {
        guard isLiquidGlassOS else { return nil }

        guard
            let glassClass = NSClassFromString("UIGlassEffect") as? NSObject.Type,
            let allocated = glassClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
            let initialised = allocated.perform(
                NSSelectorFromString("initWithStyle:"), with: NSNumber(value: style)
            )?.takeUnretainedValue(),
            let effect = initialised as? UIVisualEffect
        else {
            // Not every iOS 26 build exposes the class; absence is the documented fallback path.
            return nil
        }

        if let tint {
            effect.setValue(tint, forKey: "tintColor")
        }
        if interactive {
            effect.setValue(true, forKey: "isInteractive")
        }

        return effect
    }

    /// Builds the glass surface as a SwiftUI view, or nil when the running system cannot produce
    /// glass and the caller should fall back to its own material.
    ///
    /// This is the form call sites use. Returning nil is deliberate: the caller then draws
    /// something that suits the system it is on, rather than an empty hole where the glass
    /// would have been.
    static func makeGlassView(
        style: Int = 0,
        tint: UIColor? = nil,
        interactive: Bool = false,
        cornerRadius: CGFloat = 0
    ) -> VisualEffectView? {
        guard let effect = makeEffect(style: style, tint: tint, interactive: interactive) else {
            return nil
        }
        return VisualEffectView(effect: effect, cornerRadius: cornerRadius)
    }
}

/// Presents a UIKit visual effect view inside SwiftUI.
///
/// A `UIVisualEffectView` is a `UIView`, so it cannot be returned from a `@ViewBuilder` directly.
/// This wrapper is what lets a caller write
///
///     if let glass = SystemGlassSupport.makeGlassView() { glass } else { fallback }
///
/// in a view body.
struct VisualEffectView: UIViewRepresentable {
    let effect: UIVisualEffect?
    var cornerRadius: CGFloat

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: effect)
        applyShape(to: view)
        // The glass sits behind content that handles its own touches; the effect view must not
        // swallow them, which is the default for a view inside a Button's label.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        // A new effect object has to be assigned rather than mutated, so this is also the point
        // where a changed tint or interactive flag would take effect.
        if uiView.effect !== effect {
            uiView.effect = effect
        }
        applyShape(to: uiView)
    }

    private func applyShape(to view: UIVisualEffectView) {
        guard cornerRadius > 0 else { return }
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
    }
}