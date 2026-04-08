import Foundation

struct InvoiceDocumentMetadata: Equatable, Sendable {
    var vendor: String?
    var invoiceDate: Date?
    var invoiceNumber: String?
    var documentType: InvoiceDocumentType?

    static let empty = InvoiceDocumentMetadata(
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

    init(vendor: String?, invoiceDate: Date?, invoiceNumber: String?, documentType: InvoiceDocumentType?) {
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

    init(invoice: InvoiceItem) {
        self.init(
            vendor: invoice.vendor,
            invoiceDate: invoice.invoiceDate,
            invoiceNumber: invoice.invoiceNumber,
            documentType: invoice.documentType
        )
    }
}

struct InvoiceDocumentMember: Identifiable, Equatable, Sendable {
    let id: InvoiceItem.ID
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

struct InvoiceDocument: Identifiable, Equatable, Sendable {
    let members: [InvoiceDocumentMember]
    var metadata: InvoiceDocumentMetadata

    var id: String {
        members.map(\.identityKey).sorted().joined(separator: "|")
    }

    var memberIDs: Set<InvoiceItem.ID> {
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

    func contains(memberID: InvoiceItem.ID) -> Bool {
        members.contains { $0.id == memberID }
    }

    func member(for memberID: InvoiceItem.ID) -> InvoiceDocumentMember? {
        members.first { $0.id == memberID }
    }

    func isSoftBlocked(memberID: InvoiceItem.ID) -> Bool {
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

    func referenceMember(for memberID: InvoiceItem.ID) -> InvoiceDocumentMember? {
        members
            .filter { $0.id != memberID }
            .sorted(by: documentReferencePriority)
            .first
    }

    func duplicateInfo(for memberID: InvoiceItem.ID) -> InvoiceDuplicateInfo? {
        guard isSoftBlocked(memberID: memberID),
              let referenceMember = referenceMember(for: memberID) else {
            return nil
        }

        return InvoiceDuplicateInfo(
            duplicateOfPath: referenceMember.fileURL.path,
            reason: duplicateReason(for: referenceMember)
        )
    }

    func badgeTitle(for memberID: InvoiceItem.ID) -> String? {
        guard isSoftBlocked(memberID: memberID) else { return nil }

        if hasProcessedMember || hasInProgressMember {
            return "Duplicate Processed"
        }

        return "Duplicate"
    }

    private func duplicateReason(for referenceMember: InvoiceDocumentMember) -> String {
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

private func documentReferencePriority(lhs: InvoiceDocumentMember, rhs: InvoiceDocumentMember) -> Bool {
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
