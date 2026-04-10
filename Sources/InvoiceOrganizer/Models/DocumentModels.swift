import Foundation

struct DocumentMetadata: Equatable, Sendable {
    var vendor: String?
    var invoiceDate: Date?
    var invoiceNumber: String?
    var documentType: DocumentType?

    static let empty = DocumentMetadata(
        vendor: nil,
        invoiceDate: nil,
        invoiceNumber: nil,
        documentType: nil
    )

    var isEmpty: Bool {
        vendor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        invoiceDate == nil &&
        invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        documentType == nil
    }

    init(vendor: String?, invoiceDate: Date?, invoiceNumber: String?, documentType: DocumentType?) {
        self.vendor = vendor
        self.invoiceDate = invoiceDate
        self.invoiceNumber = invoiceNumber
        self.documentType = documentType
    }

    init(workflow: StoredInvoiceWorkflow) {
        self.init(
            vendor: workflow.vendor,
            invoiceDate: workflow.invoiceDate,
            invoiceNumber: workflow.invoiceNumber,
            documentType: workflow.documentType
        )
    }
}

struct DocumentArtifactReference: Identifiable, Equatable, Sendable {
    let id: PhysicalArtifact.ID
    let fileURL: URL
    let location: InvoiceLocation
    let addedAt: Date
    let modifiedAt: Date
    let fileType: InvoiceFileType
    let contentHash: String?

    var identityKey: String {
        let hashComponent = if let contentHash, !contentHash.isEmpty {
            "hash:\(contentHash)"
        } else {
            "hash:<missing>"
        }

        return "\(hashComponent)|path:\(id)"
    }
}

struct Document: Identifiable, Equatable, Sendable {
    let artifacts: [DocumentArtifactReference]
    var metadata: DocumentMetadata

    var id: String {
        artifacts.map(\.identityKey).sorted().joined(separator: "|")
    }

    var artifactIDs: Set<PhysicalArtifact.ID> {
        Set(artifacts.map(\.id))
    }

    var isDuplicate: Bool {
        artifacts.count > 1
    }

    var hasProcessedMember: Bool {
        artifacts.contains { $0.location == .processed }
    }

    var hasInProgressMember: Bool {
        artifacts.contains { $0.location == .processing }
    }

    func contains(artifactID: PhysicalArtifact.ID) -> Bool {
        artifacts.contains { $0.id == artifactID }
    }

    func artifact(for artifactID: PhysicalArtifact.ID) -> DocumentArtifactReference? {
        artifacts.first { $0.id == artifactID }
    }

    func bestSimilarity(
        to candidateTokens: Set<String>,
        tokensByArtifactID: [PhysicalArtifact.ID: Set<String>],
        threshold: Double
    ) -> DuplicateSimilarity? {
        let scoredArtifacts = artifacts.compactMap { artifact -> (DocumentArtifactReference, Double)? in
            guard let artifactTokens = tokensByArtifactID[artifact.id] else { return nil }
            return (artifact, DuplicateDetector.jaccardSimilarity(candidateTokens, artifactTokens))
        }

        guard let bestMatch = scoredArtifacts.max(by: { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }

            return lhs.0.id > rhs.0.id
        }) else {
            return nil
        }

        return DuplicateSimilarity(
            documentID: id,
            matchedArtifactID: bestMatch.0.id,
            matchedFileURL: bestMatch.0.fileURL,
            matchedLocation: bestMatch.0.location,
            artifactCount: artifacts.count,
            score: bestMatch.1,
            meetsThreshold: DuplicateDetector.meetsRoundedThreshold(bestMatch.1, threshold: threshold)
        )
    }

    func isSoftBlocked(artifactID: PhysicalArtifact.ID) -> Bool {
        guard isDuplicate,
              let artifact = self.artifact(for: artifactID) else { return false }

        if hasProcessedMember {
            return artifact.location != .processed
        }

        if hasInProgressMember {
            return artifact.location == .inbox
        }

        return false
    }

    func referenceArtifact(for artifactID: PhysicalArtifact.ID) -> DocumentArtifactReference? {
        artifacts
            .filter { $0.id != artifactID }
            .sorted(by: documentReferencePriority)
            .first
    }

    func duplicateInfo(forArtifactID artifactID: PhysicalArtifact.ID) -> DuplicateInfo? {
        guard isSoftBlocked(artifactID: artifactID),
              let referenceArtifact = referenceArtifact(for: artifactID) else {
            return nil
        }

        return DuplicateInfo(
            duplicateOfPath: referenceArtifact.fileURL.path,
            reason: duplicateReason(for: referenceArtifact)
        )
    }

    func badgeTitle(forArtifactID artifactID: PhysicalArtifact.ID) -> String? {
        guard isSoftBlocked(artifactID: artifactID) else { return nil }

        if hasProcessedMember || hasInProgressMember {
            return "Duplicate Processed"
        }

        return "Duplicate"
    }

    private func duplicateReason(for referenceArtifact: DocumentArtifactReference) -> String {
        switch referenceArtifact.location {
        case .processed:
            return "Similar extracted text matches processed file \(referenceArtifact.fileURL.lastPathComponent)"
        case .processing:
            return "Similar extracted text matches in-progress file \(referenceArtifact.fileURL.lastPathComponent)"
        case .inbox:
            return "Similar extracted text matches \(referenceArtifact.fileURL.lastPathComponent)"
        }
    }
}

private func documentReferencePriority(lhs: DocumentArtifactReference, rhs: DocumentArtifactReference) -> Bool {
    let lhsLocationPriority = documentReferenceLocationPriority(lhs.location)
    let rhsLocationPriority = documentReferenceLocationPriority(rhs.location)

    if lhsLocationPriority != rhsLocationPriority {
        return lhsLocationPriority < rhsLocationPriority
    }

    let lhsJPEGPriority = lhs.fileType == .jpeg ? 0 : 1
    let rhsJPEGPriority = rhs.fileType == .jpeg ? 0 : 1

    if lhsJPEGPriority != rhsJPEGPriority {
        return lhsJPEGPriority < rhsJPEGPriority
    }

    if lhs.addedAt != rhs.addedAt {
        return lhs.addedAt < rhs.addedAt
    }

    return lhs.id < rhs.id
}

private func documentReferenceLocationPriority(_ location: InvoiceLocation) -> Int {
    switch location {
    case .processed:
        return 0
    case .processing:
        return 1
    case .inbox:
        return 2
    }
}
