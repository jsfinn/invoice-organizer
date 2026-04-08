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

    init(invoice: PhysicalArtifact) {
        self.init(
            vendor: invoice.vendor,
            invoiceDate: invoice.invoiceDate,
            invoiceNumber: invoice.invoiceNumber,
            documentType: invoice.documentType
        )
    }
}

struct DocumentArtifactReference: Identifiable, Equatable, Sendable {
    let id: PhysicalArtifact.ID
    let fileURL: URL
    let location: InvoiceLocation
    let addedAt: Date
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
    let members: [DocumentArtifactReference]
    var metadata: DocumentMetadata

    var id: String {
        members.map(\.identityKey).sorted().joined(separator: "|")
    }

    var memberIDs: Set<PhysicalArtifact.ID> {
        Set(members.map(\.id))
    }

    var isDuplicate: Bool {
        members.count > 1
    }

    var hasProcessedMember: Bool {
        members.contains { $0.location == .processed }
    }

    var hasInProgressMember: Bool {
        members.contains { $0.location == .processing }
    }

    func contains(memberID: PhysicalArtifact.ID) -> Bool {
        members.contains { $0.id == memberID }
    }

    func member(for memberID: PhysicalArtifact.ID) -> DocumentArtifactReference? {
        members.first { $0.id == memberID }
    }

    func bestSimilarity(
        to candidateTokens: Set<String>,
        tokensByMemberID: [PhysicalArtifact.ID: Set<String>],
        threshold: Double
    ) -> InvoiceDuplicateSimilarity? {
        let scoredMembers = members.compactMap { member -> (DocumentArtifactReference, Double)? in
            guard let memberTokens = tokensByMemberID[member.id] else { return nil }
            return (member, InvoiceDuplicateDetector.jaccardSimilarity(candidateTokens, memberTokens))
        }

        guard let bestMatch = scoredMembers.max(by: { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }

            return lhs.0.id > rhs.0.id
        }) else {
            return nil
        }

        return InvoiceDuplicateSimilarity(
            documentID: id,
            matchedArtifactID: bestMatch.0.id,
            matchedFileURL: bestMatch.0.fileURL,
            matchedLocation: bestMatch.0.location,
            memberCount: members.count,
            score: bestMatch.1,
            meetsThreshold: bestMatch.1 >= threshold
        )
    }

    func isSoftBlocked(memberID: PhysicalArtifact.ID) -> Bool {
        guard isDuplicate,
              let member = member(for: memberID) else { return false }

        if hasProcessedMember {
            return member.location != .processed
        }

        if hasInProgressMember {
            return member.location == .inbox
        }

        return false
    }

    func referenceMember(for memberID: PhysicalArtifact.ID) -> DocumentArtifactReference? {
        members
            .filter { $0.id != memberID }
            .sorted(by: documentReferencePriority)
            .first
    }

    func duplicateInfo(for memberID: PhysicalArtifact.ID) -> InvoiceDuplicateInfo? {
        guard isSoftBlocked(memberID: memberID),
              let referenceMember = referenceMember(for: memberID) else {
            return nil
        }

        return InvoiceDuplicateInfo(
            duplicateOfPath: referenceMember.fileURL.path,
            reason: duplicateReason(for: referenceMember)
        )
    }

    func badgeTitle(for memberID: PhysicalArtifact.ID) -> String? {
        guard isSoftBlocked(memberID: memberID) else { return nil }

        if hasProcessedMember || hasInProgressMember {
            return "Duplicate Processed"
        }

        return "Duplicate"
    }

    private func duplicateReason(for referenceMember: DocumentArtifactReference) -> String {
        switch referenceMember.location {
        case .processed:
            return "Similar extracted text matches processed file \(referenceMember.fileURL.lastPathComponent)"
        case .processing:
            return "Similar extracted text matches in-progress file \(referenceMember.fileURL.lastPathComponent)"
        case .inbox:
            return "Similar extracted text matches \(referenceMember.fileURL.lastPathComponent)"
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
