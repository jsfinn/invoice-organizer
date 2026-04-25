import Foundation

@MainActor
final class PreviewViewState: ObservableObject {
    typealias MetadataFlushHandler = @MainActor (PhysicalArtifact.ID, DocumentMetadata) -> Void

    @Published private(set) var activeContext: ActivePreviewContext?

    var metadataFlushHandler: MetadataFlushHandler?

    private let assetProvider: any PreviewAssetProviding
    private let rotationCoordinator: PreviewRotationCoordinator
    private var metadataFlushTask: Task<Void, Never>?

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

    // MARK: - Preview Loading

    func loadPreview(for invoice: PhysicalArtifact, metadata: DocumentMetadata) async {
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
            metadata: metadata,
            persistedQuarterTurns: pendingQuarterTurns,
            rotationSaveStatus: saveStatus
        )

        do {
            let asset = try await assetProvider.asset(
                for: invoice.handle,
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

    // MARK: - Rotation

    func rotate(by quarterTurnsDelta: Int, for invoice: PhysicalArtifact) {
        guard activeContext?.invoice.id == invoice.id else {
            return
        }

        updateActiveContext {
            _ = $0.rotate(by: quarterTurnsDelta)
        }
    }

    // MARK: - Metadata Editing

    func updatePendingVendor(_ vendor: String?) {
        updateActiveContext { $0.pendingMetadata.vendor = vendor }
        flushMetadataImmediately()
    }

    func updatePendingInvoiceDate(_ date: Date?) {
        updateActiveContext { $0.pendingMetadata.invoiceDate = date }
        flushMetadataImmediately()
    }

    func updatePendingInvoiceNumber(_ invoiceNumber: String?) {
        updateActiveContext { $0.pendingMetadata.invoiceNumber = invoiceNumber }
        flushMetadataImmediately()
    }

    func updatePendingDocumentType(_ documentType: DocumentType?) {
        updateActiveContext { $0.pendingMetadata.documentType = documentType }
        flushMetadataImmediately()
    }

    func updatePendingMetadata(_ metadata: DocumentMetadata) {
        updateActiveContext { $0.pendingMetadata = metadata }
        flushMetadataImmediately()
    }

    /// Updates the artifact reference when the underlying file was renamed
    /// but the content stayed the same (same session).
    func syncArtifactReference(_ invoice: PhysicalArtifact, metadata: DocumentMetadata) {
        guard let activeContext,
              activeContext.sessionID == PreviewSessionID(invoice: invoice),
              activeContext.invoice.id != invoice.id else {
            return
        }

        updateActiveContext {
            $0.invoice = invoice
            $0.committedMetadata = metadata
            if !$0.isMetadataDirty {
                $0.pendingMetadata = metadata
            }
        }
    }

    // MARK: - Commit / Flush

    func scheduleCommitCurrentSessionIfNeeded() {
        guard let activeContext else {
            return
        }

        flushMetadataImmediately()
        rotationCoordinator.enqueueCommitIfNeeded(from: activeContext)
        syncSaveState(for: activeContext.invoice.id)
    }

    func flushMetadataImmediately() {
        metadataFlushTask?.cancel()
        metadataFlushTask = nil

        guard let context = activeContext, context.isMetadataDirty else {
            return
        }

        metadataFlushHandler?(context.invoice.id, context.pendingMetadata)
        updateActiveContext {
            $0.committedMetadata = $0.pendingMetadata
        }
    }

    // MARK: - Private

    private func scheduleMetadataFlush() {
        flushMetadataImmediately()
    }

    private func handoffActiveContextIfNeeded(for nextInvoice: PhysicalArtifact) {
        guard let activeContext,
              activeContext.invoice.id != nextInvoice.id else {
            return
        }

        flushMetadataImmediately()
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
