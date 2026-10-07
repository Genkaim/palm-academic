import SwiftUI
import UIKit

/// The system's own search field, hosted.
///
/// SwiftUI's `TextField` cannot be made to look and behave like `UISearchBar`: it has no cancel
/// button, no clear button, no placeholder-then-query transition and none of the keyboard type or
/// autocorrection rules that go with searching. The bottom bar needs those, and the brief is to
/// use Apple's control rather than approximate it, so `UISearchTextField` -- the exact view
/// `UISearchBar` embeds -- is hosted directly.
///
/// It is driven two ways at once, which is why it is not simply `UISearchBar`: the bar expands
/// this field in place, so the hosting view owns the layout while the SwiftUI side owns the
/// expand/collapse animation and the cancel button.
struct NativeSearchField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = "搜索"
    var isCancelVisible: Bool
    var onCancel: () -> Void
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.keyboardType = .default
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged), for: .editingChanged)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingBegan), for: .editingDidBegin)
        // `showsCancelButton` belongs to UISearchBar, not to the text field it embeds, so the
        // cancel affordance is a separate button in the SwiftUI layout instead.
        field.accessibilityLabel = placeholder
        field.text = text
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text {
            field.text = text
        }
        // A search that has been activated should own the keyboard even before the first keystroke,
        // otherwise the field is focused-looking but dead until tapped a second time.
        if isCancelVisible, !field.isFirstResponder, context.coordinator.wantsKeyboard {
            field.becomeFirstResponder()
        } else if !isCancelVisible, field.isFirstResponder {
            field.resignFirstResponder()
        }
        field.placeholder = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Retained so `updateUIView` can tell "the user just activated search" from "search was
    /// already open and the field happens to be unfocused".
    final class Coordinator: NSObject, UISearchTextFieldDelegate {
        var parent: NativeSearchField
        var wantsKeyboard = false

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UISearchTextField) {
            guard field.text != parent.text else { return }
            parent.text = field.text ?? ""
        }

        @objc func editingBegan(_ field: UISearchTextField) {
            wantsKeyboard = true
        }

        func searchTextFieldShouldReturn(_ field: UISearchTextField) -> Bool {
            parent.onSubmit()
            return true
        }

        func searchTextFieldDidEndEditing(_ field: UISearchTextField) {
            // Emptying the query dismisses the bar, which is what the system does in Mail and
            // Messages: there is nothing left to search for.
            if parent.isCancelVisible, (parent.text.isEmpty) {
                parent.onCancel()
            }
        }
    }
}