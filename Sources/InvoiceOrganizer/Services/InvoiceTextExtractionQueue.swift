import Foundation

private struct InvoiceTextExtractionRequest: Sendable {
    let contentHash: String
    let fileURL: URL
    let fileType: InvoiceFileType
}

actor InvoiceTextExtractionQueue {
    private let store: any InvoiceTextStoring
    private let extractor: any DocumentTextExtracting
    private var onRequestStarted: (@MainActor @Sendable (String) -> Void)?
    private var onRecordSaved: (@MainActor @Sendable (String) async -> Void)?
    private var onRequestFailed: (@MainActor @Sendable (String) -> Void)?

    private var pendingQueue: [InvoiceTextExtractionRequest] = []
    private var pendingHashes: Set<String> = []
    private var inFlightHashes: Set<String> = []
    private var isDraining = false

    init(
        store: any InvoiceTextStoring,
        extractor: any DocumentTextExtracting,
        onRequestStarted: (@MainActor @Sendable (String) -> Void)? = nil,
        onRecordSaved: (@MainActor @Sendable (String) async -> Void)? = nil,
        onRequestFailed: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.store = store
        self.extractor = extractor
        self.onRequestStarted = onRequestStarted
        self.onRecordSaved = onRecordSaved
        self.onRequestFailed = onRequestFailed
    }

    func setOnRecordSaved(_ handler: @escaping @MainActor @Sendable (String) async -> Void) {
        onRecordSaved = handler
    }

    func setOnRequestStarted(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        onRequestStarted = handler
    }

    func setOnRequestFailed(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        onRequestFailed = handler
    }

    func enqueue(invoices: [InvoiceItem], knownCachedHashes: Set<String>, force: Bool = false) {
        for invoice in invoices {
            guard let contentHash = invoice.contentHash,
                  (force || invoice.canPreExtractText),
                  !knownCachedHashes.contains(contentHash),
                  !pendingHashes.contains(contentHash),
                  !inFlightHashes.contains(contentHash) else {
                continue
            }

            pendingQueue.append(
                InvoiceTextExtractionRequest(
                    contentHash: contentHash,
                    fileURL: invoice.fileURL,
                    fileType: invoice.fileType
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

    private func nextRequest() -> InvoiceTextExtractionRequest? {
        guard !pendingQueue.isEmpty else { return nil }

        let request = pendingQueue.removeFirst()
        pendingHashes.remove(request.contentHash)
        inFlightHashes.insert(request.contentHash)
        return request
    }

    private func process(_ request: InvoiceTextExtractionRequest) async {
        defer {
            inFlightHashes.remove(request.contentHash)
        }

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
            return
        }
    }
}
