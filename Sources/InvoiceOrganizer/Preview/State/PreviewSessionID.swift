import Foundation

struct PreviewSessionID: Hashable {
    let invoiceID: PhysicalArtifact.ID
    let fileURL: URL
    let contentHash: String?

    init(invoice: PhysicalArtifact) {
        invoiceID = invoice.id
        fileURL = invoice.fileURL
        contentHash = invoice.contentHash
    }
}
