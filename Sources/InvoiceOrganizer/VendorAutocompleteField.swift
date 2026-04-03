import AppKit
import SwiftUI

struct VendorAutocompleteField: NSViewRepresentable {
    let text: String
    let suggestions: [String]
    let placeholder: String
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> CancelableComboBox {
        let comboBox = CancelableComboBox()
        comboBox.usesDataSource = false
        comboBox.completes = true
        comboBox.delegate = context.coordinator
        comboBox.isEditable = true
        comboBox.numberOfVisibleItems = 12
        comboBox.translatesAutoresizingMaskIntoConstraints = false
        comboBox.placeholderString = placeholder
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.committedText = text
        return comboBox
    }

    func updateNSView(_ comboBox: CancelableComboBox, context: Context) {
        context.coordinator.isUpdating = true
        context.coordinator.committedText = text
        comboBox.committedText = text

        let existingItems = comboBox.objectValues.compactMap { $0 as? String }
        if existingItems != suggestions {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: suggestions)
        }

        if !context.coordinator.isEditing, comboBox.stringValue != text {
            comboBox.stringValue = text
        }

        context.coordinator.isUpdating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
        var committedText: String
        let onCommit: (String) -> Void
        var isUpdating = false
        var isPopupOpen = false
        var pendingSelection: String?
        var isEditing = false

        init(text: String, onCommit: @escaping (String) -> Void) {
            self.committedText = text
            self.onCommit = onCommit
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard !isUpdating else { return }
            isEditing = true
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !isUpdating,
                  let comboBox = notification.object as? NSComboBox else {
                return
            }

            let selectedValue: String
            if comboBox.indexOfSelectedItem >= 0,
               let item = comboBox.itemObjectValue(at: comboBox.indexOfSelectedItem) as? String {
                selectedValue = item
            } else {
                selectedValue = comboBox.stringValue
            }

            if isPopupOpen {
                pendingSelection = selectedValue
                return
            }

            comboBox.stringValue = selectedValue
        }

        func comboBoxWillPopUp(_ notification: Notification) {
            isPopupOpen = true
            pendingSelection = nil
        }

        func comboBoxWillDismiss(_ notification: Notification) {
            defer {
                isPopupOpen = false
                pendingSelection = nil
            }

            guard !isUpdating,
                  let comboBox = notification.object as? NSComboBox,
                  let pendingSelection else {
                return
            }

            comboBox.stringValue = pendingSelection
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isUpdating,
                  let comboBox = notification.object as? CancelableComboBox else { return }

            defer { isEditing = false }

            if comboBox.isCancelling || (notification.userInfo?["NSTextMovement"] as? Int) == NSCancelTextMovement {
                comboBox.stringValue = committedText
                comboBox.isCancelling = false
                return
            }

            let updatedText = comboBox.stringValue
            guard updatedText != committedText else {
                return
            }

            committedText = updatedText
            onCommit(updatedText)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !isUpdating,
                  commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let comboBox = control as? NSComboBox else {
                return false
            }

            let updatedText = comboBox.stringValue
            if updatedText != committedText {
                committedText = updatedText
                onCommit(updatedText)
            }

            comboBox.window?.makeFirstResponder(nil)
            return true
        }
    }
}

final class CancelableComboBox: NSComboBox {
    var committedText = ""
    var isCancelling = false

    override func cancelOperation(_ sender: Any?) {
        isCancelling = true
        stringValue = committedText
        abortEditing()
        window?.makeFirstResponder(nil)
    }
}
