import SwiftUI

struct DataEntryCard: View {
    @ObservedObject var model: AppModel
    let invoice: InvoiceItem

    private var activeInvoiceID: InvoiceItem.ID {
        model.selectedInvoiceID ?? invoice.id
    }

    private var committedInvoice: InvoiceItem {
        model.selectedInvoice ?? invoice
    }

    private var documentTypeBinding: Binding<InvoiceDocumentType?> {
        Binding(
            get: { committedInvoice.documentType },
            set: { newValue in
                guard committedInvoice.documentType != newValue else { return }
                model.updateDocumentType(newValue, for: activeInvoiceID)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data Entry")
                .font(.title3.bold())

            if invoice.canEditWorkflowMetadata {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Vendor")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VendorAutocompleteField(
                        text: committedInvoice.vendor ?? "",
                        suggestions: model.knownVendors,
                        placeholder: "Vendor or Misc",
                        onCommit: { model.updateVendor($0, for: activeInvoiceID) }
                    )
                    .frame(height: 24)

                    CommitOnBlurDatePickerField(
                        date: committedInvoice.invoiceDate ?? committedInvoice.addedAt,
                        onCommit: { model.updateInvoiceDate($0, for: activeInvoiceID) }
                    )

                    Picker("Document Type", selection: documentTypeBinding) {
                        Text("Unknown").tag(Optional<InvoiceDocumentType>.none)
                        Text("Invoice").tag(Optional.some(InvoiceDocumentType.invoice))
                        Text("Receipt").tag(Optional.some(InvoiceDocumentType.receipt))
                    }

                    Text("Invoice Number")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    CommitOnBlurTextField(
                        text: committedInvoice.invoiceNumber ?? "",
                        placeholder: "Invoice Number",
                        onCommit: { model.updateInvoiceNumber($0, for: activeInvoiceID) }
                    )
                    .frame(height: 22)

                }
            } else {
                LabeledContent("Vendor", value: invoice.vendor ?? "Unassigned")
                LabeledContent("Invoice Date") {
                    Text(invoice.invoiceDate?.formatted(date: .abbreviated, time: .omitted) ?? "<missing>")
                        .foregroundStyle(invoice.invoiceDate == nil ? .secondary : .primary)
                }
                LabeledContent("Invoice Number") {
                    Text(invoice.invoiceNumber ?? "<missing>")
                        .foregroundStyle(invoice.invoiceNumber == nil ? .secondary : .primary)
                }
                LabeledContent("Document Type") {
                    Text(invoice.documentType?.rawValue ?? "<missing>")
                        .foregroundStyle(invoice.documentType == nil ? .secondary : .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
