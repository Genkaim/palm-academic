import SwiftUI
import UIKit

/// The one place that maps the Android colour tokens onto UIKit's semantic colours.
///
/// Android defines its palette twice, by hand, in `PortalTheme.kt`:
///
/// | token | light | dark |
/// |---|---|---|
/// | `primary` | `#3A3A3C` | `#D1D1D6` |
/// | `background` | `#F2F2F7` | `#000000` |
/// | `surface` | `#FFFFFF` | `#1C1C1E` |
/// | `error` | `#FF3B30` | `#FF453A` |
/// | `onSurfaceVariant` | `#636366` | `#98989D` |
/// | `outline` | `#8E8E93` | `#8E8E93` |
///
/// Every one of those has a UIKit counterpart whose value is identical, so nothing has to be
/// hand-mixed and the whole app keeps tracking the appearance:
///
/// - `#F2F2F7` / `#000000` is `systemGroupedBackground`
/// - `#FFFFFF` / `#1C1C1E` is `secondarySystemGroupedBackground` in a grouped container and
///   `systemBackground` elsewhere
/// - `#3A3A3C` / `#D1D1D6` is `label`
/// - `#FF3B30` / `#FF453A` is `systemRed`
///
/// Reading these by hand in every view is what left the earlier screens unable to follow a
/// dark-mode switch: a `Color.white.opacity(0.07)` chosen by an `isDark` flag cannot respond to
/// the system changing appearance underneath it, whereas `secondarySystemGroupedBackground` can.
enum PortalPalette {
    /// Android `background`: the page behind everything.
    static let page = Color(uiColor: .systemGroupedBackground)

    /// Android `surface`: a card or panel sitting on the page.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)

    /// A panel that is *not* part of a grouped list, such as a sheet or a full-width card.
    static let plainSurface = Color(uiColor: .systemBackground)

    /// Android `primary`, which is the near-black/near-white label colour rather than a blue.
    static let primary = Color(uiColor: .label)

    /// The colour that reads as body text on top of either surface.
    static let onSurface = Color(uiColor: .label)

    /// Android `onSurfaceVariant`: titles' secondary line, hints, captions.
    static let secondaryText = Color(uiColor: .secondaryLabel)

    /// Android `outline`: separators and disclosure chevrons.
    static let outline = Color(uiColor: .tertiaryLabel)

    /// Android `error`.
    static let error = Color(uiColor: .systemRed)

    /// The error banner's container. Android uses `errorContainer` (`#FFE5E3` light); UIKit has no
    /// token for it, so the system red is laid over the grouped surface instead of being mixed by
    /// hand, which keeps it correct in both appearances.
    static var errorContainer: Color { Color(uiColor: .systemRed).opacity(0.12) }

    /// The tint behind a settings row's glyph. iOS draws these as a rounded square filled with the
    /// colour rather than as a bare outline icon, so this is only the fill.
    static func rowGlyph(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(0.18))
    }
}

/// The glyph and colour a settings row uses, paired so a row cannot end up with an icon but no
/// colour (which is what a bare `systemImage` string tends to become).
struct PortalRowIcon {
    let systemImage: String
    let tint: Color

    init(_ systemImage: String, tint: Color) {
        self.systemImage = systemImage
        self.tint = tint
    }

    /// The system list glyph: a filled rounded square with the symbol centred in it, which is the
    /// shape `Settings` uses on iOS since 13.
    func glyph(size: CGFloat = 20, box: CGFloat = 29) -> some View {
        ZStack {
            PortalPalette.rowGlyph(tint)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: box, height: box)
    }
}

extension Color {
    /// A stable palette for the row glyphs, so "学校" is always the same blue everywhere it
    /// appears and the settings page does not read as random colour noise.
    static let portalBlue = Color(red: 0.20, green: 0.44, blue: 0.90)
    static let portalPurple = Color(red: 0.55, green: 0.36, blue: 0.86)
    static let portalGreen = Color(red: 0.20, green: 0.66, blue: 0.36)
    static let portalOrange = Color(red: 0.93, green: 0.53, blue: 0.16)
    static let portalTeal = Color(red: 0.16, green: 0.62, blue: 0.68)
    static let portalPink = Color(red: 0.92, green: 0.36, blue: 0.55)
    static let portalIndigo = Color(red: 0.35, green: 0.40, blue: 0.86)
    static let portalRed = Color(red: 0.90, green: 0.22, blue: 0.24)
}