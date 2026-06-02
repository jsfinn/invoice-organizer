import Foundation

struct PreviewCommitRequest: Sendable, Equatable {
    let handle: ArtifactHandle
    let quarterTurns: Int
    /// New page order as a permutation of `0..<pageCount`, or nil when pages are unchanged.
    let pageOrder: [Int]?

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

    init(invoice: PhysicalArtifact, quarterTurns: Int, pageOrder: [Int]? = nil) {
        self.handle = invoice.handle
        self.quarterTurns = normalizedPreviewRotationQuarterTurns(quarterTurns)
        self.pageOrder = pageOrder
    }
}
