import Foundation

struct PreviewCommitRequest: Sendable, Equatable {
    let invoiceID: PhysicalArtifact.ID
    let fileURL: URL
    let fileType: InvoiceFileType
    let contentHash: String?
    let addedAt: Date
    let quarterTurns: Int

    init(invoice: PhysicalArtifact, quarterTurns: Int) {
        self.invoiceID = invoice.id
        self.fileURL = invoice.fileURL
        self.fileType = invoice.fileType
        self.contentHash = invoice.contentHash
        self.addedAt = invoice.addedAt
        self.quarterTurns = normalizedPreviewRotationQuarterTurns(quarterTurns)
    }
}
