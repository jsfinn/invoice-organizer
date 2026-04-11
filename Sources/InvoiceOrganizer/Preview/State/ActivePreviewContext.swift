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
        self.pendingMetadata = metadata
        self.committedMetadata = metadata
    }

    var isRotationDirty: Bool {
        rotationQuarterTurns != persistedQuarterTurns
    }

    var isMetadataDirty: Bool {
        pendingMetadata != committedMetadata
    }

    var isDirty: Bool {
        isRotationDirty || isMetadataDirty
    }

    var rotationCommitRequest: PreviewCommitRequest? {
        guard isRotationDirty else { return nil }
        return PreviewCommitRequest(invoice: invoice, quarterTurns: rotationQuarterTurns)
    }

    var metadataCommitRequest: MetadataCommitRequest? {
        guard isMetadataDirty else { return nil }
        return MetadataCommitRequest(artifactID: invoice.id, metadata: pendingMetadata)
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

    mutating func updateContent(_ content: PreviewContent) {
        self.content = content
    }
}
