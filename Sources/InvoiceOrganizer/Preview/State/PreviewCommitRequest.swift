import Foundation

struct PreviewCommitRequest: Sendable, Equatable {
    let handle: ArtifactHandle
    let quarterTurns: Int

    var invoiceID: PhysicalArtifact.ID {
        handle.artifactID
    }

    var fileURL: URL {
        handle.fileURL
    }

    var fileType: InvoiceFileType {
        handle.fileType
    }

    var contentHash: String? {
        handle.contentHash
    }

    var addedAt: Date {
        handle.addedAt
    }

    init(invoice: PhysicalArtifact, quarterTurns: Int) {
        self.handle = invoice.handle
        self.quarterTurns = normalizedPreviewRotationQuarterTurns(quarterTurns)
    }
}
