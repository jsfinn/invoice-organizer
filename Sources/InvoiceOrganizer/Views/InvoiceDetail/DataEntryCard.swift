import SwiftUI

struct DataEntryCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var previewState: PreviewViewState
    let invoice: PhysicalArtifact

    @State private var vendorDraft = ""
    @State private var invoiceNumberDraft = ""
    @State private var invoiceDateDraft = Date.now
    @FocusState private var focus: DataEntryField?

    private var pendingMetadata: DocumentMetadata {
        previewState.activeContext?.pendingMetadata
            ?? model.documentMetadata(for: invoice.id)
    }

    private var documentArtifactCount: Int {
        model.document(for: invoice.id)?.artifacts.count ?? 1
    }

    private var committedVendor: String { pendingMetadata.vendor ?? "" }
    private var committedInvoiceNumber: String { pendingMetadata.invoiceNumber ?? "" }
    private var committedInvoiceDate: Date { pendingMetadata.invoiceDate ?? invoice.addedAt }

    private var vendorIsDirty: Bool {
        normalizedOptional(vendorDraft) != normalizedOptional(committedVendor)
    }

    private var invoiceNumberIsDirty: Bool {
        normalizedOptional(invoiceNumberDraft) != normalizedOptional(committedInvoiceNumber)
    }

    private var invoiceDateIsDirty: Bool {
        invoiceDateDraft != committedInvoiceDate
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
                editableContent
            } else {
                readOnlyContent
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .defaultFocus($focus, .vendor)
        .onAppear { syncDrafts(force: true) }
        .onChange(of: invoice.id) { _, _ in syncDrafts(force: true) }
        .onChange(of: pendingMetadata) { _, _ in syncDrafts() }
        .onChange(of: focus) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if let old = oldValue { commit(old) }
        }
    }

    @ViewBuilder
    private var editableContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(documentArtifactCount > 1 ? "These edits apply to the whole document." : "These edits apply to this document.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            FormField("Vendor", field: .vendor, focus: $focus, isDirty: vendorIsDirty) {
                VendorField(
                    text: $vendorDraft,
                    suggestions: model.knownVendors,
                    focus: $focus,
                    onCommit: { _ in commitVendor() }
                )
                .selectAllOnFocus(focus: $focus, whenFocused: .vendor)
            }

            FormField("Invoice Date", field: .invoiceDate, focus: $focus, isDirty: invoiceDateIsDirty) {
                DatePicker(
                    "Invoice Date",
                    selection: $invoiceDateDraft,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .focused($focus, equals: .invoiceDate)
            }

            FormField("Document Type", field: .documentType, focus: $focus) {
                let allTypes: [DocumentType?] = [nil, .invoice, .receipt]
                Picker("", selection: documentTypeBinding) {
                    Text("Unknown").tag(nil as DocumentType?)
                    Text("Invoice").tag(DocumentType.invoice as DocumentType?)
                    Text("Receipt").tag(DocumentType.receipt as DocumentType?)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .focusable()
                .focused($focus, equals: .documentType)
                .onKeyPress(.upArrow) {
                    cycleDocumentType(allTypes, delta: -1)
                }
                .onKeyPress(.downArrow) {
                    cycleDocumentType(allTypes, delta: 1)
                }
            }

            FormField("Invoice Number", field: .invoiceNumber, focus: $focus, isDirty: invoiceNumberIsDirty) {
                TextField("Invoice Number", text: $invoiceNumberDraft)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .invoiceNumber)
                    .onSubmit { commitInvoiceNumber(); focus = nextField(after: .invoiceNumber) }
                    .selectAllOnFocus(focus: $focus, whenFocused: .invoiceNumber)
            }
        }
    }

    @ViewBuilder
    private var readOnlyContent: some View {
        let metadata = model.documentMetadata(for: invoice.id)
        LabeledContent("Vendor", value: metadata.vendor ?? "Unassigned")
        LabeledContent("Invoice Date") {
            Text(metadata.invoiceDate?.formatted(date: .abbreviated, time: .omitted) ?? "<missing>")
                .foregroundStyle(metadata.invoiceDate == nil ? .secondary : .primary)
        }
        LabeledContent("Document Type") {
            Text(metadata.documentType?.rawValue ?? "<missing>")
                .foregroundStyle(metadata.documentType == nil ? .secondary : .primary)
        }
        LabeledContent("Invoice Number") {
            Text(metadata.invoiceNumber ?? "<missing>")
                .foregroundStyle(metadata.invoiceNumber == nil ? .secondary : .primary)
        }
    }

    // MARK: - Drafts

    private func syncDrafts(force: Bool = false) {
        if force || focus != .vendor {
            vendorDraft = committedVendor
        }
        if force || focus != .invoiceNumber {
            invoiceNumberDraft = committedInvoiceNumber
        }
        if force || focus != .invoiceDate {
            invoiceDateDraft = committedInvoiceDate
        }
    }

    // MARK: - Commit

    private func commit(_ field: DataEntryField) {
        switch field {
        case .vendor: commitVendor()
        case .invoiceDate: commitInvoiceDate()
        case .invoiceNumber: commitInvoiceNumber()
        case .documentType: break
        }
    }

    private func commitVendor() {
        let normalized = normalizedOptional(vendorDraft)
        vendorDraft = normalized ?? ""
        guard normalized != normalizedOptional(committedVendor) else { return }
        previewState.updatePendingVendor(normalized)
    }

    private func commitInvoiceNumber() {
        let normalized = normalizedOptional(invoiceNumberDraft)
        invoiceNumberDraft = normalized ?? ""
        guard normalized != normalizedOptional(committedInvoiceNumber) else { return }
        previewState.updatePendingInvoiceNumber(normalized)
    }

    private func commitInvoiceDate() {
        guard invoiceDateDraft != committedInvoiceDate else { return }
        previewState.updatePendingInvoiceDate(invoiceDateDraft)
    }

    // MARK: - Helpers

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cycleDocumentType(_ allTypes: [DocumentType?], delta: Int) -> KeyPress.Result {
        let current = pendingMetadata.documentType
        let idx = allTypes.firstIndex(where: { $0 == current }) ?? 0
        let next = idx + delta
        guard allTypes.indices.contains(next) else { return .ignored }
        documentTypeBinding.wrappedValue = allTypes[next]
        return .handled
    }

    private func nextField(after field: DataEntryField) -> DataEntryField? {
        switch field {
        case .vendor: return .invoiceDate
        case .invoiceDate: return .documentType
        case .documentType: return .invoiceNumber
        case .invoiceNumber: return nil
        }
    }
}
