import AppKit
import SwiftUI

struct CommitOnBlurDatePickerField: NSViewRepresentable {
    let date: Date
    let onCommit: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(date: date, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> CommitOnBlurDatePicker {
        let datePicker = CommitOnBlurDatePicker()
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.committedDate = date
        datePicker.dateValue = date
        datePicker.onCommit = { [weak coordinator = context.coordinator] updatedDate in
            coordinator?.commit(updatedDate)
        }
        datePicker.onCancel = { [weak coordinator = context.coordinator, weak datePicker] in
            coordinator?.cancel(datePicker)
        }
        return datePicker
    }

    func updateNSView(_ datePicker: CommitOnBlurDatePicker, context: Context) {
        context.coordinator.committedDate = date
        context.coordinator.onCommit = onCommit
        datePicker.committedDate = date
        datePicker.onCommit = { [weak coordinator = context.coordinator] updatedDate in
            coordinator?.commit(updatedDate)
        }
        datePicker.onCancel = { [weak coordinator = context.coordinator, weak datePicker] in
            coordinator?.cancel(datePicker)
        }
        if !datePicker.isEditingDate, datePicker.dateValue != date {
            datePicker.dateValue = date
        }
    }

    @MainActor
    final class Coordinator {
        var committedDate: Date
        var onCommit: (Date) -> Void

        init(date: Date, onCommit: @escaping (Date) -> Void) {
            self.committedDate = date
            self.onCommit = onCommit
        }

        func commit(_ updatedDate: Date) {
            guard updatedDate != committedDate else { return }
            committedDate = updatedDate
            onCommit(updatedDate)
        }

        func cancel(_ datePicker: CommitOnBlurDatePicker?) {
            guard let datePicker else { return }
            datePicker.dateValue = committedDate
            datePicker.committedDate = committedDate
        }
    }
}

final class CommitOnBlurDatePicker: NSDatePicker {
    var committedDate: Date = .now
    var onCommit: ((Date) -> Void)?
    var onBlur: (() -> Void)?
    var onCancel: (() -> Void)?
    var isEditingDate = false
    private var isCancelling = false

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            isEditingDate = true
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            defer {
                isEditingDate = false
                if isCancelling {
                    isCancelling = false
                }
            }

            if isCancelling {
                return didResign
            }

            if dateValue != committedDate {
                committedDate = dateValue
                onCommit?(dateValue)
            }

            onBlur?()
        }
        return didResign
    }

    override func cancelOperation(_ sender: Any?) {
        isCancelling = true
        dateValue = committedDate
        onCancel?()
        abortEditing()
        window?.makeFirstResponder(nil)
    }
}
