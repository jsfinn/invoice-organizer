import Foundation

struct InvoiceStructuredExtractionRequest: Sendable {
    let contentHash: String
    let settings: LLMSettings
}

final class StructuredExtractionHandler: ContentHashRequestHandler, @unchecked Sendable {
    typealias Request = InvoiceStructuredExtractionRequest

    private let textStore: any InvoiceTextStoring
    private let structuredDataStore: any InvoiceStructuredDataStoring
    private let client: any InvoiceStructuredExtractionClient

    var onRequestStarted: (@MainActor @Sendable (String) -> Void)?
    var onRecordSaved: (@MainActor @Sendable (String, InvoiceStructuredDataRecord) -> Void)?
    var onRequestFailed: (@MainActor @Sendable (String, LLMPreflightStatus) -> Void)?

    init(
        textStore: any InvoiceTextStoring,
        structuredDataStore: any InvoiceStructuredDataStoring,
        client: any InvoiceStructuredExtractionClient
    ) {
        self.textStore = textStore
        self.structuredDataStore = structuredDataStore
        self.client = client
    }

    func contentHash(for request: Request) -> String { request.contentHash }

    func process(_ request: Request) async {
        if await structuredDataStore.hasCachedData(forContentHash: request.contentHash) {
            return
        }

        guard let textRecord = await textStore.cachedText(forContentHash: request.contentHash) else {
            return
        }

        await onRequestStarted?(request.contentHash)

        do {
            guard let record = try await client.extractStructuredData(from: textRecord.text, settings: request.settings) else {
                await onRequestFailed?(
                    request.contentHash,
                    LLMPreflightStatus(state: .unavailable, message: "The LLM returned no structured fields for this invoice.")
                )
                return
            }

            await structuredDataStore.save(record, forContentHash: request.contentHash)
            await onRecordSaved?(request.contentHash, record)
        } catch let error as InvoiceStructuredExtractionClientError {
            await onRequestFailed?(request.contentHash, error.preflightStatus)
        } catch {
            await onRequestFailed?(
                request.contentHash,
                LLMPreflightStatus(
                    state: .unavailable,
                    message: error.localizedDescription
                )
            )
        }
    }

    func buildRequests(from invoices: [PhysicalArtifact], settings: LLMSettings, force: Bool = false) -> [Request] {
        invoices.compactMap { invoice in
            guard let contentHash = invoice.contentHash,
                  force || invoice.canPreExtractText else { return nil }
            return InvoiceStructuredExtractionRequest(
                contentHash: contentHash,
                settings: settings
            )
        }
    }
}
