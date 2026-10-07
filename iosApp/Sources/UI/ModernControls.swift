import SwiftUI

/// Modern filled-style text field, used by every login input.
///
/// A bare `TextField` on a card still looks like iOS 14: an underlined, transparent field with a
/// grey placeholder floating on whatever is behind it. The system filled field instead paints a
/// rounded grey container with the label inside it, which is what iOS 16 onwards apps use. SwiftUI
/// has no first-party modifier for that, so the container is drawn here and the `TextField` is
/// kept transparent on top of it.
///
/// The decoration layers all carry `allowsHitTesting(false)`. A shape that participates in hit
/// testing swallows the first tap meant for the text field, so the caret only appears on the
/// second one.
struct FilledTextField: View {
    let title: String
    let systemImage: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: UITextContentType?
    var autocapitalization: TextInputAutocapitalization = .never
    var submitLabel: SubmitLabel = .next
    var isDark: Bool
    var isDisabled: Bool = false
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            input
                .focused($isFocused)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit() }
                .disabled(isDisabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(container)
        .overlay(border)
        // Pressing anywhere in the field should focus it, not only the glyph and the text.
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .opacity(isDisabled ? 0.55 : 1)
    }

    @ViewBuilder
    private var input: some View {
        if isSecure {
            SecureField(title, text: $text)
                .textContentType(contentType)
        } else {
            TextField(title, text: $text)
                .textContentType(contentType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
        }
    }

    private var iconColor: Color {
        if isFocused { return .accentColor }
        return isDark ? Color.white.opacity(0.55) : Color.secondary
    }

    /// The grey rounded container the system filled field uses. It brightens slightly while
    /// focused, which is the affordance that tells the user the tap landed.
    private var container: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                isFocused
                    ? (isDark ? Color.white.opacity(0.14) : Color.white)
                    : (isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.045))
            )
            .allowsHitTesting(false)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isFocused
                    ? Color.accentColor.opacity(0.7)
                    : (isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)),
                lineWidth: isFocused ? 1.4 : 0.8
            )
            .allowsHitTesting(false)
    }
}

/// Pressable container matching the filled fields, used for the login and web-login actions.
///
/// `.buttonStyle(.plain)` alone gives a dead tap with no feedback, which reads as "the app did
/// not register this". The scale spring plus the brightness step restores the response the
/// system buttons have for free.
struct FilledActionButton: View {
    enum Style {
        case prominent
        case plain
    }

    let title: String
    let systemImage: String
    var style: Style = .prominent
    var isDark: Bool
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(border)
            .contentShape(Rectangle())
        }
        // The press feedback lives in the style rather than in @State: a ButtonStyle already
        // knows whether it is pressed, so the button body does not need its own flag.
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var foreground: Color {
        switch style {
        case .prominent: return .white
        case .plain: return isDark ? Color.white : Color.accentColor
        }
    }

    /// Wrapped in `AnyShapeStyle` so the two cases can differ in type — a gradient versus a flat
    /// colour — which a bare `switch` inside `.fill()` cannot express under the Swift 5 language
    /// mode used by this target.
    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(fillStyle)
            .allowsHitTesting(false)
    }

    private var fillStyle: AnyShapeStyle {
        switch style {
        case .prominent:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(red: 0.24, green: 0.52, blue: 0.94),
                             Color(red: 0.16, green: 0.40, blue: 0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .plain:
            return AnyShapeStyle(isDark ? Color.white.opacity(0.1) : Color.white.opacity(0.75))
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                style == .plain ? (isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)) : .clear,
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
    }
}

/// Supplies the press feedback a `.buttonStyle(.plain)` button otherwise loses: a small scale
/// dip plus a brightness step, which is what makes a tappable surface feel tappable.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
