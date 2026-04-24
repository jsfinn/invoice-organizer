import Foundation

struct FilenameIntent: Equatable, Sendable {
    let artifactID: PhysicalArtifact.ID
    let currentURL: URL
    let vendor: String?
    let invoiceDate: Date?
    let invoiceNumber: String?
    let fileType: InvoiceFileType
}

struct FilenameRenameResult: Sendable {
    let artifactID: PhysicalArtifact.ID
    let newURL: URL
    let newName: String
}

actor FilenameReconciler {
    private var pending: [PhysicalArtifact.ID: FilenameIntent] = [:]
    private var continuation: AsyncStream<FilenameRenameResult>.Continuation?
    private var drainTask: Task<Void, Never>?
    private let identityStore: PhysicalArtifactIdentityStore

    let results: AsyncStream<FilenameRenameResult>

    init(identityStore: PhysicalArtifactIdentityStore = .shared) {
        self.identityStore = identityStore
        var captured: AsyncStream<FilenameRenameResult>.Continuation?
        self.results = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func schedule(_ intent: FilenameIntent) {
        pending[intent.artifactID] = intent
        scheduleDrain()
    }

    func drain() async {
        drainTask?.cancel()
        drainTask = nil
        await drainPending()
    }

    private func scheduleDrain() {
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            await self?.drainPending()
        }
    }

    private func drainPending() async {
        let snapshot = pending
        pending.removeAll()

        for (_, intent) in snapshot {
            do {
                let result = try await performRename(intent)
                if let result {
                    continuation?.yield(result)
                }
            } catch {
                // Rename failed — leave the file as-is. The next reconciliation
                // will pick up the correct state from disk.
            }
        }
    }

    private func performRename(_ intent: FilenameIntent) async throws -> FilenameRenameResult? {
        try await Task.detached(priority: .utility) { [identityStore] in
            let renamedURL = try InvoiceWorkspaceMover.renameInProcessing(
                PhysicalArtifact(
                    id: intent.artifactID,
                    name: intent.currentURL.lastPathComponent,
                    fileURL: intent.currentURL,
                    location: .processing,
                    addedAt: .now,
                    fileType: intent.fileType,
                    status: .inProgress
                ),
                vendor: intent.vendor,
                invoiceDate: intent.invoiceDate,
                invoiceNumber: intent.invoiceNumber
            )

            guard renamedURL != intent.currentURL else { return nil }

            identityStore.updateURL(from: intent.currentURL, to: renamedURL)
            identityStore.save()

            return FilenameRenameResult(
                artifactID: intent.artifactID,
                newURL: renamedURL,
                newName: renamedURL.lastPathComponent
            )
        }.value
    }
}
