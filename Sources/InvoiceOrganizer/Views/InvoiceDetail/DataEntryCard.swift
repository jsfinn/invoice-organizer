import SwiftUI

struct DataEntryCard: View {
    @ObservedObject var model: AppModel
    let invoice: PhysicalArtifact

    private var activeInvoiceID: PhysicalArtifact.ID {
        model.selectedArtifactID ?? invoice.id
    }

    private var committedInvoice: PhysicalArtifact {
        model.selectedArtifact ?? invoice
    }

    private var committedMetadata: DocumentMetadata {
        model.documentMetadata(for: activeInvoiceID)
    }

    private var documentArtifactCount: Int {
        model.document(for: activeInvoiceID)?.artifacts.count ?? 1
    }

    private var documentTypeBinding: Binding<DocumentType?> {
        Binding(
            get: { committedMetadata.documentType },
            set: { newValue in
                guard committedMetadata.documentType != newValue else { return }
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
                    Text(documentArtifactCount > 1 ? "These edits apply to the whole document." : "These edits apply to this document.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Vendor")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VendorAutocompleteField(
                        text: committedMetadata.vendor ?? "",
                        suggestions: model.knownVendors,
                        placeholder: "Vendor or Misc",
                        onCommit: { model.updateVendor($0, for: activeInvoiceID) }
                    )
                    .frame(height: 24)

                    CommitOnBlurDatePickerField(
                        date: committedMetadata.invoiceDate ?? committedInvoice.addedAt,
                        onCommit: { model.updateInvoiceDate($0, for: activeInvoiceID) }
                    )

                    Picker("Document Type", selection: documentTypeBinding) {
                        Text("Unknown").tag(Optional<DocumentType>.none)
                        Text("Invoice").tag(Optional.some(DocumentType.invoice))
                        Text("Receipt").tag(Optional.some(DocumentType.receipt))
                    }

                    Text("Invoice Number")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    CommitOnBlurTextField(
                        text: committedMetadata.invoiceNumber ?? "",
                        placeholder: "Invoice Number",
                        onCommit: { model.updateInvoiceNumber($0, for: activeInvoiceID) }
                    )
                    .frame(height: 22)

                }
            } else {
                let metadata = model.documentMetadata(for: invoice.id)
                LabeledContent("Vendor", value: metadata.vendor ?? "Unassigned")
                LabeledContent("Invoice Date") {
                    Text(metadata.invoiceDate?.formatted(date: .abbreviated, time: .omitted) ?? "<missing>")
                        .foregroundStyle(metadata.invoiceDate == nil ? .secondary : .primary)
                }
                LabeledContent("Invoice Number") {
                    Text(metadata.invoiceNumber ?? "<missing>")
                        .foregroundStyle(metadata.invoiceNumber == nil ? .secondary : .primary)
                }
                LabeledContent("Document Type") {
                    Text(metadata.documentType?.rawValue ?? "<missing>")
                        .foregroundStyle(metadata.documentType == nil ? .secondary : .primary)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
