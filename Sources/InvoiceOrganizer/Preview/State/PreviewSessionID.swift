import Foundation

struct PreviewSessionID: Hashable {
    let contentHash: String?
    let fileType: InvoiceFileType

    init(invoice: PhysicalArtifact) {
        contentHash = invoice.contentHash
        fileType = invoice.fileType
    }
}
