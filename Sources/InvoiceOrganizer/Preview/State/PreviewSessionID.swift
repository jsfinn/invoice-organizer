import Foundation

struct PreviewSessionID: Hashable {
    let invoiceID: InvoiceItem.ID
    let fileURL: URL
    let contentHash: String?

    init(invoice: InvoiceItem) {
        invoiceID = invoice.id
        fileURL = invoice.fileURL
        contentHash = invoice.contentHash
    }
}
