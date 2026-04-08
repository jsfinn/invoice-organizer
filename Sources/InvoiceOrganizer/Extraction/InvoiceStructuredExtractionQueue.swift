import Foundation

private struct InvoiceStructuredExtractionRequest: Sendable {
    let contentHash: String
    let settings: LLMSettings
}

actor InvoiceStructuredExtractionQueue {
    private let textStore: any InvoiceTextStoring
    private let structuredDataStore: any InvoiceStructuredDataStoring
    private let client: any InvoiceStructuredExtractionClient
    private var onRequestStarted: (@MainActor @Sendable (String) -> Void)?
    private var onRecordSaved: (@MainActor @Sendable (String, InvoiceStructuredDataRecord) -> Void)?
    private var onRequestFailed: (@MainActor @Sendable (String, LLMPreflightStatus) -> Void)?

    private var pendingQueue: [InvoiceStructuredExtractionRequest] = []
    private var pendingHashes: Set<String> = []
    private var inFlightHashes: Set<String> = []
    private var isDraining = false

    init(
        textStore: any InvoiceTextStoring,
        structuredDataStore: any InvoiceStructuredDataStoring,
        client: any InvoiceStructuredExtractionClient,
        onRequestStarted: (@MainActor @Sendable (String) -> Void)? = nil,
        onRecordSaved: (@MainActor @Sendable (String, InvoiceStructuredDataRecord) -> Void)? = nil,
        onRequestFailed: (@MainActor @Sendable (String, LLMPreflightStatus) -> Void)? = nil
    ) {
        self.textStore = textStore
        self.structuredDataStore = structuredDataStore
        self.client = client
        self.onRequestStarted = onRequestStarted
        self.onRecordSaved = onRecordSaved
        self.onRequestFailed = onRequestFailed
    }

    func setOnRecordSaved(_ handler: @escaping @MainActor @Sendable (String, InvoiceStructuredDataRecord) -> Void) {
        onRecordSaved = handler
    }

    func setOnRequestStarted(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        onRequestStarted = handler
    }

    func setOnRequestFailed(_ handler: @escaping @MainActor @Sendable (String, LLMPreflightStatus) -> Void) {
        onRequestFailed = handler
    }

    func enqueue(invoices: [PhysicalArtifact], knownStructuredHashes: Set<String>, settings: LLMSettings, force: Bool = false) {
        for invoice in invoices {
            guard let contentHash = invoice.contentHash,
                  (force || invoice.canPreExtractText),
                  !knownStructuredHashes.contains(contentHash),
                  !pendingHashes.contains(contentHash),
                  !inFlightHashes.contains(contentHash) else {
                continue
            }

            pendingQueue.append(
                InvoiceStructuredExtractionRequest(
                    contentHash: contentHash,
                    settings: settings
                )
            )
            pendingHashes.insert(contentHash)
        }

        guard !isDraining, !pendingQueue.isEmpty else { return }
        isDraining = true

        Task.detached(priority: .utility) { [self] in
            await drainQueue()
        }
    }

    func waitForIdle() async {
        while isDraining || !pendingQueue.isEmpty || !inFlightHashes.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func drainQueue() async {
        while let request = nextRequest() {
            await process(request)
        }

        isDraining = false

        if !pendingQueue.isEmpty {
            isDraining = true
            Task.detached(priority: .utility) { [self] in
                await drainQueue()
            }
        }
    }

    private func nextRequest() -> InvoiceStructuredExtractionRequest? {
        guard !pendingQueue.isEmpty else { return nil }

        let request = pendingQueue.removeFirst()
        pendingHashes.remove(request.contentHash)
        inFlightHashes.insert(request.contentHash)
        return request
    }

    private func process(_ request: InvoiceStructuredExtractionRequest) async {
        defer {
            inFlightHashes.remove(request.contentHash)
        }

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
}
