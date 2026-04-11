import SwiftUI

struct DataEntryCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var previewState: PreviewViewState
    let invoice: PhysicalArtifact

    private var pendingMetadata: DocumentMetadata {
        previewState.activeContext?.pendingMetadata
            ?? model.documentMetadata(for: invoice.id)
    }

    private var documentArtifactCount: Int {
        model.document(for: invoice.id)?.artifacts.count ?? 1
    }

    private var documentTypeBinding: Binding<DocumentType?> {
        Binding(
            get: { pendingMetadata.documentType },
            set: { newValue in
                guard pendingMetadata.documentType != newValue else { return }
                previewState.updatePendingDocumentType(newValue)
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
                        text: pendingMetadata.vendor ?? "",
                        suggestions: model.knownVendors,
                        placeholder: "Vendor or Misc",
                        onCommit: { value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            previewState.updatePendingVendor(trimmed.isEmpty ? nil : trimmed)
                        }
                    )
                    .frame(height: 24)

                    CommitOnBlurDatePickerField(
                        date: pendingMetadata.invoiceDate ?? invoice.addedAt,
                        onCommit: { previewState.updatePendingInvoiceDate($0) }
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
                        text: pendingMetadata.invoiceNumber ?? "",
                        placeholder: "Invoice Number",
                        onCommit: { value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            previewState.updatePendingInvoiceNumber(trimmed.isEmpty ? nil : trimmed)
                        }
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
