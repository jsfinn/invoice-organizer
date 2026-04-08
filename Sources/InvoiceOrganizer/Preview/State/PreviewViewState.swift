import Foundation

@MainActor
final class PreviewViewState: ObservableObject {
    @Published private(set) var activeContext: ActivePreviewContext?

    private let assetProvider: any PreviewAssetProviding
    private let rotationCoordinator: PreviewRotationCoordinator

    init(
        assetProvider: any PreviewAssetProviding,
        rotationCoordinator: PreviewRotationCoordinator
    ) {
        self.assetProvider = assetProvider
        self.rotationCoordinator = rotationCoordinator
    }

    var content: PreviewContent {
        activeContext?.content ?? .loading
    }

    var sessionID: PreviewSessionID? {
        activeContext?.sessionID
    }

    var rotationQuarterTurns: Int {
        activeContext?.rotationQuarterTurns ?? 0
    }

    var rotationSaveStatus: PreviewRotationCoordinator.SaveStatus {
        activeContext?.rotationSaveStatus ?? .idle
    }

    func loadPreview(for invoice: PhysicalArtifact) async {
        let nextSessionID = PreviewSessionID(invoice: invoice)
        let isSameRevision = activeContext?.sessionID == nextSessionID

        handoffActiveContextIfNeeded(for: invoice)

        if isSameRevision,
           let activeContext,
           case .asset = activeContext.content {
            syncSaveState(for: invoice.id)
            return
        }

        let pendingQuarterTurns = rotationCoordinator.pendingQuarterTurns(for: invoice.id) ?? 0
        let saveStatus = rotationCoordinator.saveStatus(for: invoice.id)
        activeContext = ActivePreviewContext(
            invoice: invoice,
            persistedQuarterTurns: pendingQuarterTurns,
            rotationSaveStatus: saveStatus
        )

        do {
            let asset = try await assetProvider.asset(
                for: invoice.fileURL,
                contentHash: invoice.contentHash,
                fileType: invoice.fileType,
                forceReload: false
            )
            guard !Task.isCancelled,
                  activeContext?.sessionID == nextSessionID else {
                return
            }

            updateActiveContext {
                $0.updateContent(.asset(asset))
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeContext?.sessionID == nextSessionID else {
                return
            }

            let title = invoice.fileType == .pdf ? "Unable To Open PDF" : "Unable To Open Image"
            updateActiveContext {
                $0.updateContent(.error(title: title, message: error.localizedDescription))
            }
        }
    }

    func rotate(by quarterTurnsDelta: Int, for invoice: PhysicalArtifact) {
        guard activeContext?.invoice.id == invoice.id else {
            return
        }

        updateActiveContext {
            _ = $0.rotate(by: quarterTurnsDelta)
        }
    }

    func scheduleCommitCurrentSessionIfNeeded() {
        guard let activeContext else {
            return
        }

        rotationCoordinator.enqueueCommitIfNeeded(from: activeContext)
        syncSaveState(for: activeContext.invoice.id)
    }

    private func handoffActiveContextIfNeeded(for nextInvoice: PhysicalArtifact) {
        guard let activeContext,
              activeContext.invoice.id != nextInvoice.id else {
            return
        }

        rotationCoordinator.enqueueCommitIfNeeded(from: activeContext)
    }

    private func syncSaveState(for invoiceID: PhysicalArtifact.ID) {
        updateActiveContext {
            guard $0.invoice.id == invoiceID else { return }
            $0.rotationSaveStatus = rotationCoordinator.saveStatus(for: invoiceID)
        }
    }

    private func updateActiveContext(_ update: (inout ActivePreviewContext) -> Void) {
        guard var activeContext else {
            return
        }

        update(&activeContext)
        self.activeContext = activeContext
    }
}
