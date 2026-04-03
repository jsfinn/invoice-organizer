import Foundation

struct PreviewRotationDraft: Sendable, Equatable {
    let invoiceID: InvoiceItem.ID
    let fileURL: URL
    let fileType: InvoiceFileType
    let contentHash: String?
    let addedAt: Date
    let quarterTurns: Int

    init(invoice: InvoiceItem, quarterTurns: Int) {
        self.invoiceID = invoice.id
        self.fileURL = invoice.fileURL
        self.fileType = invoice.fileType
        self.contentHash = invoice.contentHash
        self.addedAt = invoice.addedAt
        self.quarterTurns = normalizedPreviewRotationQuarterTurns(quarterTurns)
    }
}

@MainActor
final class PreviewRotationCoordinator: ObservableObject {
    typealias PersistHandler = @Sendable (PreviewRotationDraft) async -> PreviewRotationSaveResult?

    var persistHandler: PersistHandler?

    private var draftsByInvoiceID: [InvoiceItem.ID: PreviewRotationDraft] = [:]
    private var commitTasksByInvoiceID: [InvoiceItem.ID: Task<Void, Never>] = [:]

    var hasPendingWork: Bool {
        !draftsByInvoiceID.isEmpty || !commitTasksByInvoiceID.isEmpty
    }

    func updateDraft(for invoice: InvoiceItem, quarterTurns: Int) {
        let draft = PreviewRotationDraft(invoice: invoice, quarterTurns: quarterTurns)
        if draft.quarterTurns == 0 {
            draftsByInvoiceID.removeValue(forKey: invoice.id)
        } else {
            draftsByInvoiceID[invoice.id] = draft
        }
    }

    func quarterTurns(for invoiceID: InvoiceItem.ID) -> Int {
        draftsByInvoiceID[invoiceID]?.quarterTurns ?? 0
    }

    func commitDraftIfNeeded(for invoiceID: InvoiceItem.ID?) {
        guard let invoiceID,
              commitTasksByInvoiceID[invoiceID] == nil,
              let draft = draftsByInvoiceID[invoiceID],
              let persistHandler else {
            return
        }

        commitTasksByInvoiceID[invoiceID] = Task { [weak self] in
            let result = await persistHandler(draft)
            await MainActor.run {
                guard let self else { return }
                self.commitTasksByInvoiceID.removeValue(forKey: invoiceID)
                if result != nil, self.draftsByInvoiceID[invoiceID] == draft {
                    self.draftsByInvoiceID.removeValue(forKey: invoiceID)
                }
            }
        }
    }

    func commitAllPendingDrafts() async {
        for invoiceID in draftsByInvoiceID.keys {
            commitDraftIfNeeded(for: invoiceID)
        }

        let tasks = Array(commitTasksByInvoiceID.values)
        for task in tasks {
            await task.value
        }
    }
}
