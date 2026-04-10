import Foundation

struct InvoiceTextExtractionRequest: Sendable {
    let contentHash: String
    let fileURL: URL
    let fileType: InvoiceFileType
}

final class TextExtractionHandler: ContentHashRequestHandler, @unchecked Sendable {
    typealias Request = InvoiceTextExtractionRequest

    private let store: any InvoiceTextStoring
    private let extractor: any DocumentTextExtracting

    var onRequestStarted: (@MainActor @Sendable (String) -> Void)?
    var onRecordSaved: (@MainActor @Sendable (String) async -> Void)?
    var onRequestFailed: (@MainActor @Sendable (String) -> Void)?

    init(store: any InvoiceTextStoring, extractor: any DocumentTextExtracting) {
        self.store = store
        self.extractor = extractor
    }

    func contentHash(for request: Request) -> String { request.contentHash }

    func process(_ request: Request) async {
        if await store.hasCachedText(forContentHash: request.contentHash) {
            return
        }

        await onRequestStarted?(request.contentHash)

        do {
            guard let record = try await extractor.extractText(from: request.fileURL, fileType: request.fileType) else {
                await onRequestFailed?(request.contentHash)
                return
            }

            await store.save(record, forContentHash: request.contentHash)
            await onRecordSaved?(request.contentHash)
        } catch {
            await onRequestFailed?(request.contentHash)
        }
    }

    func buildRequests(from invoices: [PhysicalArtifact], force: Bool = false) -> [Request] {
        invoices.compactMap { invoice in
            guard let contentHash = invoice.contentHash,
                  force || invoice.canPreExtractText else { return nil }
            return InvoiceTextExtractionRequest(
                contentHash: contentHash,
                fileURL: invoice.fileURL,
                fileType: invoice.fileType
            )
        }
    }
}
