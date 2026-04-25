import SwiftUI

enum DataEntryField: Hashable {
    case vendor
    case invoiceDate
    case documentType
    case invoiceNumber
    case saveButton
    case saveAndNextButton
}

struct FormField<Content: View>: View {
    let label: String
    let field: DataEntryField
    @FocusState.Binding var focus: DataEntryField?
    let isDirty: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ label: String,
        field: DataEntryField,
        focus: FocusState<DataEntryField?>.Binding,
        isDirty: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.field = field
        self._focus = focus
        self.isDirty = isDirty
        self.content = content
    }

    private var isFocused: Bool { focus == field }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }

            content()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isFocused ? 1.5 : 0.5)
                )
        }
    }
}
