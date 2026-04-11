import Foundation

struct PreviewRotationSaveResult: Sendable {
    let contentHash: String?
}

@MainActor
/// Coordinates background persistence for immutable preview commit requests.
///
/// Use this object to:
/// - enqueue rotation commits after an active preview context is handed off
/// - query the pending rotation and save status for a file
/// - persist one queued request or all pending requests, either in the background or by awaiting completion
final class PreviewRotationCoordinator: ObservableObject {
    typealias PersistHandler = @Sendable (PreviewCommitRequest) async -> PreviewRotationSaveResult?

    /// Tracks whether a queued request is idle, actively saving, or failed to save.
    enum SaveStatus: Equatable {
        case idle
        case saving
        case failed
    }

    private struct CommitEntry: Equatable {
        var request: PreviewCommitRequest
        var saveStatus: SaveStatus
    }

    var persistHandler: PersistHandler?

    private var entriesByInvoiceID: [PhysicalArtifact.ID: CommitEntry] = [:]
    private var commitTasksByInvoiceID: [PhysicalArtifact.ID: Task<Void, Never>] = [:]

    /// Returns `true` when there are queued commit requests or save tasks still running.
    var hasPendingWork: Bool {
        !entriesByInvoiceID.isEmpty || !commitTasksByInvoiceID.isEmpty
    }

    /// Enqueues a background commit from an active context if that context has unsaved rotation changes.
    func enqueueCommitIfNeeded(from context: ActivePreviewContext?) {
        guard let request = context?.rotationCommitRequest else {
            return
        }

        entriesByInvoiceID[request.invoiceID] = CommitEntry(request: request, saveStatus: .idle)
        scheduleCommitIfNeeded(for: request.invoiceID)
    }

    /// Returns the currently queued or in-flight quarter-turn value for an invoice, if any.
    func pendingQuarterTurns(for invoiceID: PhysicalArtifact.ID) -> Int? {
        entriesByInvoiceID[invoiceID]?.request.quarterTurns
    }

    /// Returns the current save status for an invoice's queued rotation commit.
    func saveStatus(for invoiceID: PhysicalArtifact.ID) -> SaveStatus {
        if let entry = entriesByInvoiceID[invoiceID] {
            return entry.saveStatus
        }
        return commitTasksByInvoiceID[invoiceID] == nil ? .idle : .saving
    }

    /// Starts saving a queued request in a background task if one exists and is not already saving.
    ///
    /// This method is not async and returns immediately.
    func scheduleCommitIfNeeded(for invoiceID: PhysicalArtifact.ID?) {
        guard let invoiceID,
              commitTasksByInvoiceID[invoiceID] == nil,
              entriesByInvoiceID[invoiceID] != nil else {
            return
        }

        Task { [weak self] in
            await self?.commitRequestIfNeeded(for: invoiceID)
        }
    }

    /// Saves a queued request immediately if needed and waits for the save to finish.
    ///
    /// If a save for the same invoice is already running, this awaits the existing task.
    func commitRequestIfNeeded(for invoiceID: PhysicalArtifact.ID?) async {
        guard let invoiceID,
              let entry = entriesByInvoiceID[invoiceID],
              let persistHandler else {
            return
        }

        if let existingTask = commitTasksByInvoiceID[invoiceID] {
            await existingTask.value
            return
        }

        let request = entry.request
        entriesByInvoiceID[invoiceID]?.saveStatus = .saving

        commitTasksByInvoiceID[invoiceID] = Task { [weak self] in
            let result = await persistHandler(request)
            await MainActor.run {
                guard let self else { return }
                self.commitTasksByInvoiceID.removeValue(forKey: invoiceID)
                guard let currentEntry = self.entriesByInvoiceID[invoiceID],
                      currentEntry.request == request else {
                    return
                }

                if result != nil {
                    self.entriesByInvoiceID.removeValue(forKey: invoiceID)
                } else {
                    self.entriesByInvoiceID[invoiceID]?.saveStatus = .failed
                }
            }
        }

        await commitTasksByInvoiceID[invoiceID]?.value
    }

    /// Saves every pending commit request and waits for all of them to complete.
    func commitAllPendingRequests() async {
        for invoiceID in Array(entriesByInvoiceID.keys) {
            await commitRequestIfNeeded(for: invoiceID)
        }
    }
}
