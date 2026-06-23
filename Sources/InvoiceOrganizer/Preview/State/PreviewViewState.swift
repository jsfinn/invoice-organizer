import Foundation

@MainActor
final class PreviewViewState: ObservableObject {
    typealias MetadataFlushHandler = @MainActor (PhysicalArtifact.ID, DocumentMetadata) -> Void
    /// Persists a rotation delta (in quarter turns) to disk immediately and returns the
    /// resulting save info (including the new content hash). When set, rotation is written
    /// on every rotate instead of being deferred to handoff/quit.
    typealias RotationPersistHandler = @MainActor (PhysicalArtifact.ID, Int) async -> PreviewRotationSaveResult?

    @Published private(set) var activeContext: ActivePreviewContext?

    var metadataFlushHandler: MetadataFlushHandler?
    var rotationPersistHandler: RotationPersistHandler?

    private let assetProvider: any PreviewAssetProviding
    private let rotationCoordinator: PreviewRotationCoordinator
    private var rotationSaveTask: Task<Void, Never>?

    init(
        assetProvider: any PreviewAssetProviding,
        rotationCoordinator: PreviewRotationCoordinator
    ) {
        self.assetProvider = assetProvider
        self.rotationCoordinator = rotationCoordinator

        // Make the coordinator's quit/handoff flush also wait for in-flight immediate
        // rotation saves so a rotate immediately followed by quit is never lost.
        rotationCoordinator.externalPendingWork = { [weak self] in self?.rotationSaveTask != nil }
        rotationCoordinator.externalFlush = { [weak self] in await self?.rotationSaveTask?.value }
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

    var pageOrder: [Int] {
        activeContext?.pageOrder ?? []
    }

    var rotationSaveStatus: PreviewRotationCoordinator.SaveStatus {
        activeContext?.rotationSaveStatus ?? .idle
    }

    // MARK: - Preview Loading

    func loadPreview(for invoice: PhysicalArtifact, metadata: DocumentMetadata) async {
        let nextSessionID = PreviewSessionID(invoice: invoice)

        await handoffActiveContextIfNeeded(for: invoice)

        // Same artifact already on screen: keep the live preview (and any rotation
        // overlay) rather than flashing a reload. This covers in-place rotation saves
        // that change the content hash without changing what the user sees.
        if let active = activeContext,
           active.invoice.id == invoice.id,
           case .asset = active.content {
            updateActiveContext {
                $0.invoice = invoice
                if !$0.isMetadataDirty {
                    $0.pendingMetadata = metadata
                    $0.committedMetadata = metadata
                }
            }
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

            let pendingOrder = rotationCoordinator.pendingPageOrder(for: invoice.id)
            updateActiveContext {
                $0.updateContent(.asset(asset))
                if case .pdf(let document) = asset {
                    $0.setPageCount(document.pageCount, pendingOrder: pendingOrder)
                }
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

        scheduleRotationPersist()
    }

    // MARK: - Immediate Rotation Persistence

    /// Starts (or lets the running drain pick up) immediate persistence of the active
    /// context's unsaved rotation. No-op when no immediate handler is configured, in
    /// which case rotation is committed later via the rotation coordinator.
    private func scheduleRotationPersist() {
        guard rotationPersistHandler != nil, rotationSaveTask == nil else {
            return
        }

        rotationSaveTask = Task { [weak self] in
            await self?.drainRotationPersist()
        }
    }

    /// Persists rotation deltas to disk one at a time until the active context is no
    /// longer dirty. Each successful save advances the persisted baseline (without
    /// reloading the asset, so the preview never flickers) and absorbs the new content
    /// hash so later saves apply only the remaining delta.
    private func drainRotationPersist() async {
        defer { rotationSaveTask = nil }

        while let context = activeContext,
              context.uncommittedRotationQuarterTurns != 0,
              let persist = rotationPersistHandler {
            let invoiceID = context.invoice.id
            let target = context.rotationQuarterTurns
            let delta = context.uncommittedRotationQuarterTurns

            updateActiveContext {
                guard $0.invoice.id == invoiceID else { return }
                $0.rotationSaveStatus = .saving
            }

            let result = await persist(invoiceID, delta)

            guard let result else {
                updateActiveContext {
                    guard $0.invoice.id == invoiceID else { return }
                    $0.rotationSaveStatus = .failed
                }
                return
            }

            updateActiveContext {
                guard $0.invoice.id == invoiceID else { return }
                $0.markRotationPersisted(upTo: target)
                $0.rotationSaveStatus = .idle
                if let updatedHash = result.contentHash {
                    $0.invoice.contentHash = updatedHash
                }
            }
        }
    }

    // MARK: - Page Reordering

    /// Updates the in-memory page order for the active document. `order` is a permutation
    /// of `0..<pageCount`. The change is held in memory (and reflected live in the preview);
    /// it is written to disk once on handoff/quit via the commit coordinator, mirroring rotation.
    func reorderPages(_ order: [Int], for invoice: PhysicalArtifact) {
        guard activeContext?.invoice.id == invoice.id else { return }
        updateActiveContext { _ = $0.reorderPages(order) }
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
        scheduleRotationPersist()
        enqueuePendingCommit(from: activeContext)
        syncSaveState(for: activeContext.invoice.id)
    }

    func flushMetadataImmediately() {
        guard let context = activeContext, context.isMetadataDirty else {
            return
        }

        metadataFlushHandler?(context.invoice.id, context.pendingMetadata)
        updateActiveContext {
            $0.committedMetadata = $0.pendingMetadata
        }
    }

    // MARK: - Private

    private func handoffActiveContextIfNeeded(for nextInvoice: PhysicalArtifact) async {
        guard let activeContext,
              activeContext.invoice.id != nextInvoice.id else {
            return
        }

        // Let any immediate rotation save for the outgoing invoice finish so it is
        // never re-committed (and double-applied) by the coordinator below.
        await rotationSaveTask?.value

        flushMetadataImmediately()
        if let context = self.activeContext, context.invoice.id != nextInvoice.id {
            enqueuePendingCommit(from: context)
        }
    }

    /// Enqueues unsaved edits for background persistence. When immediate rotation
    /// persistence is active, rotation has already been written on each rotate, so only
    /// page-order changes are routed through the coordinator here.
    private func enqueuePendingCommit(from context: ActivePreviewContext) {
        guard rotationPersistHandler != nil else {
            rotationCoordinator.enqueueCommitIfNeeded(from: context)
            return
        }

        guard context.isPageOrderDirty else {
            return
        }

        rotationCoordinator.enqueueCommit(
            PreviewCommitRequest(
                invoice: context.invoice,
                quarterTurns: 0,
                pageOrder: context.pageOrder
            )
        )
    }

    private func syncSaveState(for invoiceID: PhysicalArtifact.ID) {
        // The immediate rotation save owns the save status while it is running; don't
        // clobber it with the coordinator's (rotation-agnostic) status.
        guard rotationSaveTask == nil else { return }
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
