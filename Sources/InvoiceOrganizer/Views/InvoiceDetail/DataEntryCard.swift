import SwiftUI

struct DataEntryCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var previewState: PreviewViewState
    let invoice: PhysicalArtifact

    @State private var vendorDraft = ""
    @State private var invoiceNumberDraft = ""
    @State private var invoiceDateDraft = Date.now
    @State private var documentTypeDraft: DocumentType?
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
    private var committedDocumentType: DocumentType? { pendingMetadata.documentType }

    private var vendorIsDirty: Bool {
        normalizedOptional(vendorDraft) != normalizedOptional(committedVendor)
    }

    private var invoiceNumberIsDirty: Bool {
        normalizedOptional(invoiceNumberDraft) != normalizedOptional(committedInvoiceNumber)
    }

    private var invoiceDateIsDirty: Bool {
        invoiceDateDraft != committedInvoiceDate
    }

    private var documentTypeIsDirty: Bool {
        documentTypeDraft != committedDocumentType
    }

    private var isDirty: Bool {
        vendorIsDirty || invoiceDateIsDirty || documentTypeIsDirty || invoiceNumberIsDirty
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
                    focus: $focus
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

            FormField("Document Type", field: .documentType, focus: $focus, isDirty: documentTypeIsDirty) {
                let allTypes: [DocumentType?] = [nil, .invoice, .receipt]
                Picker("", selection: $documentTypeDraft) {
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
                    .onSubmit { saveAll() }
                    .selectAllOnFocus(focus: $focus, whenFocused: .invoiceNumber)
            }

            HStack {
                Button("Save") { saveAll() }
                    .keyboardShortcut("s", modifiers: .command)
                    .focusable()
                    .focused($focus, equals: .saveButton)
                    .onKeyPress(.return) { saveAll(); return .handled }
                Button("Save and Next") { saveAndNext() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .focusable()
                    .focused($focus, equals: .saveAndNextButton)
                    .onKeyPress(.return) { saveAndNext(); return .handled }
                Spacer()
                Button("Save and Move to Processed") { saveAndMoveToProcessed() }
                    .focusable()
                    .focused($focus, equals: .moveToProcessedButton)
                    .onKeyPress(.return) { saveAndMoveToProcessed(); return .handled }
            }
            .padding(.top, 4)
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
        if force || focus != .documentType {
            documentTypeDraft = committedDocumentType
        }
    }

    // MARK: - Save

    private func saveAll() {
        guard isDirty else { return }

        let vendor = normalizedOptional(vendorDraft)
        vendorDraft = vendor ?? ""
        let invoiceNumber = normalizedOptional(invoiceNumberDraft)
        invoiceNumberDraft = invoiceNumber ?? ""

        var metadata = pendingMetadata
        metadata.vendor = vendor
        metadata.invoiceDate = invoiceDateDraft
        metadata.documentType = documentTypeDraft
        metadata.invoiceNumber = invoiceNumber
        previewState.updatePendingMetadata(metadata)
    }

    private func saveAndNext() {
        saveAll()
        model.selectNextArtifact()
    }

    private func saveAndMoveToProcessed() {
        saveAll()
        model.moveInvoicesToProcessed(ids: [invoice.id])
    }

    // MARK: - Helpers

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cycleDocumentType(_ allTypes: [DocumentType?], delta: Int) -> KeyPress.Result {
        let idx = allTypes.firstIndex(where: { $0 == documentTypeDraft }) ?? 0
        let next = idx + delta
        guard allTypes.indices.contains(next) else { return .ignored }
        documentTypeDraft = allTypes[next]
        return .handled
    }

}
