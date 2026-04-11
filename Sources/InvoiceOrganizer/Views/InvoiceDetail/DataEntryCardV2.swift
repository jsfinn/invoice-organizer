import SwiftUI

struct DataEntryCardV2: View {
    @ObservedObject var model: AppModel
    @ObservedObject var previewState: PreviewViewState
    let invoice: PhysicalArtifact

    @State private var vendorDraft = ""
    @State private var invoiceNumberDraft = ""
    @State private var invoiceDateDraft = Date.now
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case vendor
        case invoiceNumber
        case invoiceDate
    }

    private var pendingMetadata: DocumentMetadata {
        previewState.activeContext?.pendingMetadata
            ?? model.documentMetadata(for: invoice.id)
    }

    private var documentArtifactCount: Int {
        model.document(for: invoice.id)?.artifacts.count ?? 1
    }

    private var committedVendor: String {
        pendingMetadata.vendor ?? ""
    }

    private var committedInvoiceNumber: String {
        pendingMetadata.invoiceNumber ?? ""
    }

    private var committedInvoiceDate: Date {
        pendingMetadata.invoiceDate ?? invoice.addedAt
    }

    private var vendorIsDirty: Bool {
        focusedField == .vendor && normalizedOptionalText(vendorDraft) != normalizedOptionalText(committedVendor)
    }

    private var invoiceNumberIsDirty: Bool {
        focusedField == .invoiceNumber && normalizedOptionalText(invoiceNumberDraft) != normalizedOptionalText(committedInvoiceNumber)
    }

    private var invoiceDateIsDirty: Bool {
        focusedField == .invoiceDate && invoiceDateDraft != committedInvoiceDate
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

                    FormField("Vendor", isDirty: vendorIsDirty) {
                        VendorAutocompleteFieldV2(
                            text: $vendorDraft,
                            suggestions: model.knownVendors,
                            placeholder: "Vendor or Misc",
                            onEditingChanged: handleVendorEditingChange,
                            onCommit: commitVendor
                        )
                    }

                    FormField("Invoice Number", isDirty: invoiceNumberIsDirty) {
                        TextField("Invoice Number", text: $invoiceNumberDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .invoiceNumber)
                            .onSubmit(commitInvoiceNumber)
                    }

                    FormField("Invoice Date", isDirty: invoiceDateIsDirty) {
                        DatePicker(
                            "Invoice Date",
                            selection: $invoiceDateDraft,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .focused($focusedField, equals: .invoiceDate)
                    }

                    FormField("Document Type") {
                        Picker("Document Type", selection: documentTypeBinding) {
                            Text("Unknown").tag(Optional<DocumentType>.none)
                            Text("Invoice").tag(Optional.some(DocumentType.invoice))
                            Text("Receipt").tag(Optional.some(DocumentType.receipt))
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            } else {
                let metadata = model.documentMetadata(for: invoice.id)
                LabeledContent("Vendor", value: metadata.vendor ?? "Unassigned")
                LabeledContent("Invoice Number") {
                    Text(metadata.invoiceNumber ?? "<missing>")
                        .foregroundStyle(metadata.invoiceNumber == nil ? .secondary : .primary)
                }
                LabeledContent("Invoice Date") {
                    Text(metadata.invoiceDate?.formatted(date: .abbreviated, time: .omitted) ?? "<missing>")
                        .foregroundStyle(metadata.invoiceDate == nil ? .secondary : .primary)
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
        .onAppear {
            syncDrafts(force: true)
        }
        .onChange(of: invoice.id) { _, _ in
            syncDrafts(force: true)
        }
        .onChange(of: pendingMetadata) { _, _ in
            syncDrafts()
        }
        .onChange(of: focusedField) { oldValue, newValue in
            guard oldValue != newValue else { return }

            if oldValue == .invoiceNumber {
                commitInvoiceNumber()
            }

            if oldValue == .invoiceDate {
                commitInvoiceDate()
            }
        }
    }

    private func handleVendorEditingChange(_ isEditing: Bool) {
        if isEditing {
            focusedField = .vendor
        } else if focusedField == .vendor {
            focusedField = nil
        }
    }

    private func syncDrafts(force: Bool = false) {
        if force || focusedField != .vendor {
            vendorDraft = committedVendor
        }

        if force || focusedField != .invoiceNumber {
            invoiceNumberDraft = committedInvoiceNumber
        }

        if force || focusedField != .invoiceDate {
            invoiceDateDraft = committedInvoiceDate
        }
    }

    private func commitVendor() {
        let normalizedDraft = normalizedOptionalText(vendorDraft)
        vendorDraft = normalizedDraft ?? ""
        guard normalizedDraft != normalizedOptionalText(committedVendor) else { return }
        previewState.updatePendingVendor(normalizedDraft)
    }

    private func commitInvoiceNumber() {
        let normalizedDraft = normalizedOptionalText(invoiceNumberDraft)
        invoiceNumberDraft = normalizedDraft ?? ""
        guard normalizedDraft != normalizedOptionalText(committedInvoiceNumber) else { return }
        previewState.updatePendingInvoiceNumber(normalizedDraft)
    }

    private func commitInvoiceDate() {
        guard invoiceDateDraft != committedInvoiceDate else { return }
        previewState.updatePendingInvoiceDate(invoiceDateDraft)
    }

    private func normalizedOptionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct FormField<Content: View>: View {
    let label: String
    var isDirty = false
    @ViewBuilder let content: () -> Content

    init(_ label: String, isDirty: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.isDirty = isDirty
        self.content = content
    }

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
        }
    }
}
