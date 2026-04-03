import AppKit
import SwiftUI

struct CommitOnBlurTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> CommitOnBlurTextFieldControl {
        let textField = CommitOnBlurTextFieldControl()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.committedText = text
        return textField
    }

    func updateNSView(_ textField: CommitOnBlurTextFieldControl, context: Context) {
        context.coordinator.committedText = text
        context.coordinator.onCommit = onCommit
        textField.committedText = text
        if !context.coordinator.isEditing, textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var committedText: String
        var onCommit: (String) -> Void
        var isEditing = false

        init(text: String, onCommit: @escaping (String) -> Void) {
            self.committedText = text
            self.onCommit = onCommit
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? CommitOnBlurTextFieldControl else { return }
            defer { isEditing = false }

            if textField.isCancelling || (notification.userInfo?["NSTextMovement"] as? Int) == NSCancelTextMovement {
                textField.stringValue = committedText
                textField.isCancelling = false
                return
            }

            let updatedText = textField.stringValue
            guard updatedText != committedText else { return }
            committedText = updatedText
            onCommit(updatedText)
        }
    }
}

final class CommitOnBlurTextFieldControl: NSTextField {
    var committedText = ""
    var isCancelling = false

    override func cancelOperation(_ sender: Any?) {
        isCancelling = true
        stringValue = committedText
        abortEditing()
        window?.makeFirstResponder(nil)
    }
}
