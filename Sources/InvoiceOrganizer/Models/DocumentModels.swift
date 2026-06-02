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

    init(
        id: PhysicalArtifact.ID,
        fileURL: URL,
        location: InvoiceLocation,
        addedAt: Date,
        modifiedAt: Date? = nil,
        fileType: InvoiceFileType,
        contentHash: String?
    ) {
        self.id = id
        self.fileURL = fileURL
        self.location = location
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt ?? addedAt
        self.fileType = fileType
        self.contentHash = contentHash
    }

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

    var preferredArtifact: DocumentArtifactReference? {
        artifacts
            .filter { $0.location != .processed }
            .sorted { $0.fileType.duplicatePriority < $1.fileType.duplicatePriority }
            .first
    }

    func bestSimilarity(
        to candidateTerms: [String: Int],
        termFrequenciesByArtifactID: [PhysicalArtifact.ID: [String: Int]],
        documentFrequencies: [String: Int],
        documentCount: Int,
        threshold: Double
    ) -> DuplicateSimilarity? {
        let scoredArtifacts = artifacts.compactMap { artifact -> (DocumentArtifactReference, Double)? in
            guard let artifactTerms = termFrequenciesByArtifactID[artifact.id] else { return nil }
            let score = DuplicateDetector.cosineSimilarity(
                lhs: candidateTerms, rhs: artifactTerms,
                documentFrequencies: documentFrequencies, documentCount: documentCount
            )
            return (artifact, score)
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
            meetsThreshold: bestMatch.1 >= threshold
        )
    }

    func matchKind(forArtifactID artifactID: PhysicalArtifact.ID) -> DuplicateMatchKind? {
        guard isDuplicate else { return nil }
        guard let artifact = self.artifact(for: artifactID),
              let reference = referenceArtifact(for: artifactID) else {
            return nil
        }
        if let hash = artifact.contentHash,
           let refHash = reference.contentHash,
           hash == refHash {
            return .identicalFile
        }
        return .sameDocument
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
            reason: duplicateReason(for: referenceArtifact, artifactID: artifactID)
        )
    }

    func badgeTitle(forArtifactID artifactID: PhysicalArtifact.ID) -> String? {
        guard isSoftBlocked(artifactID: artifactID) else { return nil }

        switch matchKind(forArtifactID: artifactID) {
        case .identicalFile:
            return "Identical Copy"
        case .sameDocument, nil:
            if hasProcessedMember || hasInProgressMember {
                return "Duplicate Processed"
            }
            return "Duplicate"
        }
    }

    private func duplicateReason(
        for referenceArtifact: DocumentArtifactReference,
        artifactID: PhysicalArtifact.ID
    ) -> String {
        let fileName = referenceArtifact.fileURL.lastPathComponent
        let kind = matchKind(forArtifactID: artifactID)

        switch kind {
        case .identicalFile:
            return "Identical copy of \(fileName)"
        case .sameDocument, nil:
            switch referenceArtifact.location {
            case .processed:
                return "Similar extracted text matches processed file \(fileName)"
            case .processing:
                return "Similar extracted text matches in-progress file \(fileName)"
            case .inbox:
                return "Similar extracted text matches \(fileName)"
            }
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
