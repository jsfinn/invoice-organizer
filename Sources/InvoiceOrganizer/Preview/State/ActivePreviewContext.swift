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
    let invoice: PhysicalArtifact
    let sessionID: PreviewSessionID
    var content: PreviewContent
    var rotationQuarterTurns: Int
    var persistedQuarterTurns: Int
    var rotationSaveStatus: PreviewRotationCoordinator.SaveStatus

    init(
        invoice: PhysicalArtifact,
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
    }

    var isDirty: Bool {
        rotationQuarterTurns != persistedQuarterTurns
    }

    var commitRequest: PreviewCommitRequest? {
        guard isDirty else { return nil }
        return PreviewCommitRequest(invoice: invoice, quarterTurns: rotationQuarterTurns)
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
