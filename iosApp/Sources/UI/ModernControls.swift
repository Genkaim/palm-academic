import SwiftUI
import UIKit

/// The system text field, hosted.
///
/// SwiftUI's `TextField` cannot toggle `isSecureTextEntry` on an existing instance, so revealing
/// the password used to mean building a second field and swapping it in — which also threw away
/// the in-flight editing state. Hosting `UITextField` gives the real control instead: UIKit draws
/// the rounded border, the caret, the autofill chrome and the iOS 26 treatment on its own, and the
/// reveal toggle becomes a property write on the same view.
///
/// Height is pinned rather than left to `intrinsicContentSize`, whose 34pt is the iOS 13-era box
/// and looks cramped next to a 44pt system row.
struct NativeLoginField: UIViewRepresentable {
    let title: String
    let systemImage: String
    @Binding var text: String
    /// Bound rather than a plain flag: the reveal button lives inside UIKit, so toggling it has
    /// to travel back to SwiftUI to keep the two sides in step.
    @Binding var isSecure: Bool
    var contentType: UITextContentType?
    var submitLabel: UIReturnKeyType = .next
    var isDisabled: Bool = false
    /// Mirrors first-responder state so the caller can move focus between fields.
    @Binding var isFocused: Bool
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)
        field.textContentType = contentType
        field.returnKeyType = submitLabel
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.accessibilityLabel = title
        // The clear button and the reveal button both want the trailing slot, and UIKit only has
        // room for one. Username keeps the clear button; the password field gets the eye.
        field.clearButtonMode = isSecure ? .never : .whileEditing
        field.leftView = iconView()
        field.leftViewMode = .always
        if isSecure {
            field.rightView = context.coordinator.makeRevealButton()
            field.rightViewMode = .always
        }
        context.coordinator.applySecure(isSecure, to: field, text: text)
        field.text = text
        field.isEnabled = !isDisabled
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text {
            field.text = text
        }
        // Flipping the flag clears UIKit's internal editing buffer, so the value has to be written
        // back; without this the field goes blank the moment the eye is tapped.
        if field.isSecureTextEntry != isSecure {
            context.coordinator.applySecure(isSecure, to: field, text: field.text)
        }
        field.isEnabled = !isDisabled
        field.alpha = isDisabled ? 0.5 : 1
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder, !isDisabled {
            field.resignFirstResponder()
        }
    }

    private func iconView() -> UIImageView {
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let view = UIImageView(image: UIImage(systemName: systemImage, withConfiguration: configuration))
        view.tintColor = .secondaryLabel
        view.contentMode = .center
        view.frame = CGRect(x: 0, y: 0, width: 34, height: 24)
        return view
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeLoginField
        /// Guards the programmatic write that follows the reveal toggle, so restoring the text
        /// does not re-enter the editing-changed callback and fight the binding.
        private var isRestoring = false

        init(parent: NativeLoginField) {
            self.parent = parent
        }

        func applySecure(_ secure: Bool, to field: UITextField, text: String?) {
            isRestoring = true
            field.isSecureTextEntry = secure
            field.text = text
            isRestoring = false
        }

        @objc func editingChanged(_ field: UITextField) {
            guard !isRestoring, field.text != parent.text else { return }
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            parent.isFocused = false
        }

        func makeRevealButton() -> UIButton {
            let button = UIButton(type: .system)
            button.addTarget(self, action: #selector(toggleReveal), for: .touchUpInside)
            button.frame = CGRect(x: 0, y: 0, width: 40, height: 24)
            button.tintColor = .secondaryLabel
            updateRevealIcon(button)
            return button
        }

        @objc private func toggleReveal(_ sender: UIButton) {
            parent.$isSecure.wrappedValue.toggle()
            updateRevealIcon(sender)
        }

        private func updateRevealIcon(_ button: UIButton) {
            let name = parent.isSecure ? "eye" : "eye.slash"
            let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            button.setImage(UIImage(systemName: name, withConfiguration: configuration), for: .normal)
            button.accessibilityLabel = parent.isSecure ? "显示密码" : "隐藏密码"
        }
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
