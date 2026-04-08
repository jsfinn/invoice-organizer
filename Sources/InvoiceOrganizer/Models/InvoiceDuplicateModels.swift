import Foundation

struct InvoiceDuplicateInfo: Equatable, Sendable {
    let duplicateOfPath: String
    let reason: String
}

struct InvoiceDuplicateGroup: Equatable, Identifiable, Sendable {
    let members: [InvoiceDuplicateMember]

    var id: String {
        members.map(\.id).sorted().joined(separator: "|")
    }

    var memberIDs: Set<String> {
        Set(members.map(\.id))
    }

    var hasProcessedMember: Bool {
        members.contains { $0.location == .processed }
    }

    var hasInProgressMember: Bool {
        members.contains { $0.location == .processing }
    }

    func contains(memberID: String) -> Bool {
        members.contains { $0.id == memberID }
    }

    func member(for memberID: String) -> InvoiceDuplicateMember? {
        members.first { $0.id == memberID }
    }

    func isSoftBlocked(memberID: String) -> Bool {
        guard let member = member(for: memberID) else { return false }

        if hasProcessedMember {
            return member.location != .processed
        }

        if hasInProgressMember {
            return member.location == .inbox
        }

        return false
    }

    func referenceMember(for memberID: String) -> InvoiceDuplicateMember? {
        members
            .filter { $0.id != memberID }
            .sorted(by: duplicateReferencePriority)
            .first
    }

    func duplicateInfo(for memberID: String) -> InvoiceDuplicateInfo? {
        guard isSoftBlocked(memberID: memberID),
              let referenceMember = referenceMember(for: memberID) else {
            return nil
        }

        return InvoiceDuplicateInfo(
            duplicateOfPath: referenceMember.fileURL.path,
            reason: duplicateReason(for: referenceMember)
        )
    }

    func badgeTitle(for memberID: String) -> String? {
        guard isSoftBlocked(memberID: memberID) else { return nil }

        if hasProcessedMember || hasInProgressMember {
            return "Duplicate Processed"
        }

        return "Duplicate"
    }

    private func duplicateReason(for referenceMember: InvoiceDuplicateMember) -> String {
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

struct InvoiceDuplicateMember: Identifiable, Equatable, Sendable {
    let id: String
    let fileURL: URL
    let location: InvoiceLocation
    let addedAt: Date
    let fileType: InvoiceFileType
}

private func duplicateReferencePriority(lhs: InvoiceDuplicateMember, rhs: InvoiceDuplicateMember) -> Bool {
    let lhsLocationPriority = duplicateReferenceLocationPriority(lhs.location)
    let rhsLocationPriority = duplicateReferenceLocationPriority(rhs.location)

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

private func duplicateReferenceLocationPriority(_ location: InvoiceLocation) -> Int {
    switch location {
    case .processed:
        return 0
    case .processing:
        return 1
    case .inbox:
        return 2
    }
}
