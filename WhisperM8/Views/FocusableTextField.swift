import SwiftUI
import AppKit

/// A TextField wrapper that works properly in LSUIElement (menu bar) apps
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSecure: Bool = false
    /// Return im Feld (optional).
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let textField: NSTextField
        if isSecure {
            textField = NSSecureTextField()
        } else {
            textField = NSTextField()
        }
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.bezelStyle = .roundedBezel
        textField.stringValue = text
        textField.focusRingType = .exterior
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Placeholder mitführen — er ist dynamisch (z. B. maskierte Dots bei
        // gespeichertem Key, Provider-Name), makeNSView allein reicht nicht.
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        // Force the window to be key so text field can receive input
        DispatchQueue.main.async {
            nsView.window?.makeKey()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTextField

        init(_ parent: FocusableTextField) {
            self.parent = parent
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let onSubmit = parent.onSubmit else { return false }
            onSubmit()
            return true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }
    }
}
