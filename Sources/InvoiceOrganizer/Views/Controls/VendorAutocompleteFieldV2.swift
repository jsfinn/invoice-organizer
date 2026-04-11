import AppKit
import SwiftUI

struct VendorAutocompleteFieldV2: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    let placeholder: String
    var onEditingChanged: (Bool) -> Void = { _ in }
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            suggestions: suggestions,
            onEditingChanged: onEditingChanged,
            onCommit: onCommit
        )
    }

    func makeNSView(context: Context) -> CancelableComboBoxV2 {
        let comboBox = CancelableComboBoxV2()
        comboBox.usesDataSource = true
        comboBox.completes = true
        comboBox.dataSource = context.coordinator
        comboBox.delegate = context.coordinator
        comboBox.isEditable = true
        comboBox.numberOfVisibleItems = 12
        comboBox.placeholderString = placeholder
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.committedText = text
        comboBox.stringValue = text
        context.coordinator.comboBox = comboBox
        return comboBox
    }

    func updateNSView(_ comboBox: CancelableComboBoxV2, context: Context) {
        context.coordinator.isUpdating = true
        context.coordinator.text = $text
        context.coordinator.onEditingChanged = onEditingChanged
        context.coordinator.committedText = text
        context.coordinator.onCommit = onCommit
        comboBox.committedText = text

        if context.coordinator.allSuggestions != suggestions {
            context.coordinator.allSuggestions = suggestions
            context.coordinator.refilter()
            comboBox.reloadData()
        }

        if !context.coordinator.isEditing, comboBox.stringValue != text {
            comboBox.stringValue = text
        }

        comboBox.placeholderString = placeholder
        context.coordinator.isUpdating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource, NSTextFieldDelegate {
        var text: Binding<String>
        var committedText: String
        var onEditingChanged: (Bool) -> Void
        var onCommit: () -> Void
        var allSuggestions: [String]
        var filteredSuggestions: [String]
        var isUpdating = false
        var isEditing = false
        weak var comboBox: CancelableComboBoxV2?

        init(
            text: Binding<String>,
            suggestions: [String],
            onEditingChanged: @escaping (Bool) -> Void,
            onCommit: @escaping () -> Void
        ) {
            self.text = text
            self.committedText = text.wrappedValue
            self.onEditingChanged = onEditingChanged
            self.onCommit = onCommit
            self.allSuggestions = suggestions
            self.filteredSuggestions = suggestions
        }

        func refilter() {
            guard let comboBox else {
                filteredSuggestions = allSuggestions
                return
            }

            let query = comboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                filteredSuggestions = allSuggestions
            } else {
                filteredSuggestions = allSuggestions.filter {
                    $0.localizedCaseInsensitiveContains(query)
                }
            }
        }

        func numberOfItems(in comboBox: NSComboBox) -> Int {
            filteredSuggestions.count
        }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard index >= 0, index < filteredSuggestions.count else { return nil }
            return filteredSuggestions[index]
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            allSuggestions.first {
                $0.commonPrefix(with: string, options: .caseInsensitive).count == string.count
            }
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            filteredSuggestions.firstIndex { $0.caseInsensitiveCompare(string) == .orderedSame } ?? NSNotFound
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isUpdating, let comboBox = notification.object as? CancelableComboBoxV2 else { return }
            text.wrappedValue = comboBox.stringValue
            refilter()
            comboBox.reloadData()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard !isUpdating else { return }
            isEditing = true
            onEditingChanged(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isUpdating, let comboBox = notification.object as? CancelableComboBoxV2 else { return }

            defer {
                isEditing = false
                onEditingChanged(false)
                filteredSuggestions = allSuggestions
            }

            if comboBox.isCancelling || (notification.userInfo?["NSTextMovement"] as? Int) == NSCancelTextMovement {
                comboBox.stringValue = committedText
                text.wrappedValue = committedText
                comboBox.isCancelling = false
                return
            }

            let updatedText = comboBox.stringValue
            text.wrappedValue = updatedText
            guard updatedText != committedText else { return }
            committedText = updatedText
            onCommit()
        }
    }
}

final class CancelableComboBoxV2: NSComboBox {
    var committedText = ""
    var isCancelling = false

    override func cancelOperation(_ sender: Any?) {
        isCancelling = true
        stringValue = committedText
        abortEditing()
        window?.makeFirstResponder(nil)
    }
}
