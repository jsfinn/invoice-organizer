enum PreviewContent {
    case loading
    case error(title: String, message: String)
    case asset(PreviewAsset)
}

func normalizedPreviewRotationQuarterTurns(_ value: Int) -> Int {
    let normalized = value % 4
    return normalized >= 0 ? normalized : normalized + 4
}

struct ActivePreviewContext {
    var invoice: PhysicalArtifact
    let sessionID: PreviewSessionID
    var content: PreviewContent

    // MARK: - Rotation

    var rotationQuarterTurns: Int
    var persistedQuarterTurns: Int
    var rotationSaveStatus: PreviewRotationCoordinator.SaveStatus

    // MARK: - Page Order

    /// Current in-memory page order (permutation of `0..<pageCount`). Empty until the
    /// PDF asset has loaded and the page count is known.
    var pageOrder: [Int]
    var persistedPageOrder: [Int]

    // MARK: - Metadata

    var pendingMetadata: DocumentMetadata
    var committedMetadata: DocumentMetadata

    init(
        invoice: PhysicalArtifact,
        metadata: DocumentMetadata,
        persistedQuarterTurns: Int,
        rotationSaveStatus: PreviewRotationCoordinator.SaveStatus
    ) {
        let normalizedRotation = normalizedPreviewRotationQuarterTurns(persistedQuarterTurns)
        self.invoice = invoice
        self.sessionID = PreviewSessionID(invoice: invoice)
        self.content = .loading
        self.rotationQuarterTurns = normalizedRotation
        self.persistedQuarterTurns = normalizedRotation
        self.rotationSaveStatus = rotationSaveStatus
        self.pageOrder = []
        self.persistedPageOrder = []
        self.pendingMetadata = metadata
        self.committedMetadata = metadata
    }

    var isRotationDirty: Bool {
        rotationQuarterTurns != persistedQuarterTurns
    }

    /// The rotation (in quarter turns, normalized to 0..<4) that still needs to be
    /// written to disk to make the file match the on-screen preview. This is the
    /// delta to apply, not the absolute orientation, so it can be applied on top of
    /// a file that already reflects `persistedQuarterTurns`.
    var uncommittedRotationQuarterTurns: Int {
        normalizedPreviewRotationQuarterTurns(rotationQuarterTurns - persistedQuarterTurns)
    }

    /// Marks rotation up to `target` as having been written to disk. Used by the
    /// immediate (per-rotate) persistence path so subsequent saves only apply the
    /// remaining delta and `isRotationDirty` reflects the true unsaved state.
    mutating func markRotationPersisted(upTo target: Int) {
        persistedQuarterTurns = normalizedPreviewRotationQuarterTurns(target)
    }

    var isPageOrderDirty: Bool {
        !pageOrder.isEmpty && pageOrder != persistedPageOrder
    }

    var isMetadataDirty: Bool {
        pendingMetadata != committedMetadata
    }

    /// A commit request capturing any unsaved rotation and/or page-order changes.
    var editCommitRequest: PreviewCommitRequest? {
        guard isRotationDirty || isPageOrderDirty else { return nil }
        return PreviewCommitRequest(
            invoice: invoice,
            quarterTurns: rotationQuarterTurns,
            pageOrder: isPageOrderDirty ? pageOrder : nil
        )
    }

    mutating func rotate(by quarterTurnsDelta: Int) -> Bool {
        let updatedRotation = normalizedPreviewRotationQuarterTurns(
            rotationQuarterTurns + quarterTurnsDelta
        )
        guard updatedRotation != rotationQuarterTurns else {
            return false
        }

        rotationQuarterTurns = updatedRotation
        rotationSaveStatus = .idle
        return true
    }

    /// Establishes the known page count once the PDF asset has loaded, optionally
    /// restoring a still-pending (unsaved) order queued by the commit coordinator.
    mutating func setPageCount(_ count: Int, pendingOrder: [Int]?) {
        let identity = Array(0..<max(count, 0))
        persistedPageOrder = identity

        if let pendingOrder,
           pendingOrder.count == count,
           Set(pendingOrder) == Set(identity) {
            pageOrder = pendingOrder
        } else {
            pageOrder = identity
        }
    }

    mutating func reorderPages(_ newOrder: [Int]) -> Bool {
        guard !pageOrder.isEmpty,
              newOrder.count == pageOrder.count,
              Set(newOrder) == Set(pageOrder),
              newOrder != pageOrder else {
            return false
        }

        pageOrder = newOrder
        rotationSaveStatus = .idle
        return true
    }

    mutating func updateContent(_ content: PreviewContent) {
        self.content = content
    }
}
