import Foundation

/// Canonical representation of a document's structural identity derived from LLM-extracted
/// metadata. Replaces the previous `StructuredDuplicateSignature` and `SameInvoiceSignature`
/// with a single type and consistent normalization.
///
/// The identity has two key predicates:
/// - `isPositiveMatch(_:)` — full structural equality, safe for unconditional grouping
/// - `conflicts(with:)` — provably different documents, vetoes text-based grouping
struct DocumentIdentity: Hashable, Sendable {
    let vendor: String
    let invoiceDate: Date
    let documentType: DocumentType
    let invoiceNumber: String?

    init?(record: InvoiceStructuredDataRecord) {
        guard let vendor = Self.normalizedField(record.companyName),
              let invoiceDate = record.invoiceDate,
              let documentType = record.documentType else {
            return nil
        }

        self.vendor = vendor
        self.invoiceDate = invoiceDate
        self.documentType = documentType
        self.invoiceNumber = Self.normalizedField(record.invoiceNumber)
    }

    init?(metadata: DocumentMetadata) {
        guard let vendor = Self.normalizedField(metadata.vendor),
              let invoiceDate = metadata.invoiceDate,
              let documentType = metadata.documentType else {
            return nil
        }

        self.vendor = vendor
        self.invoiceDate = invoiceDate
        self.documentType = documentType
        self.invoiceNumber = Self.normalizedField(metadata.invoiceNumber)
    }

    /// Full structural equality: requires all shared fields to match.
    /// For `.invoice` type, both sides must have a non-nil invoice number.
    /// Receipts match on vendor + date + type alone.
    func isPositiveMatch(_ other: DocumentIdentity) -> Bool {
        guard vendor == other.vendor,
              invoiceDate == other.invoiceDate,
              documentType == other.documentType else {
            return false
        }

        switch documentType {
        case .invoice:
            guard let lhsNumber = invoiceNumber,
                  let rhsNumber = other.invoiceNumber else {
                return false
            }
            return lhsNumber == rhsNumber
        case .receipt:
            return true
        }
    }

    /// Returns true when these two identities represent provably different documents.
    /// Any single field conflict is sufficient because a document's identity fields
    /// are intrinsic — the same document always carries the same values.
    func conflicts(with other: DocumentIdentity) -> Bool {
        if vendor != other.vendor { return true }
        if invoiceDate != other.invoiceDate { return true }
        if let lhsNumber = invoiceNumber,
           let rhsNumber = other.invoiceNumber,
           lhsNumber != rhsNumber {
            return true
        }
        return false
    }

    /// Human-readable explanation of the first conflict found, or nil if none.
    func conflictReason(with other: DocumentIdentity) -> String? {
        if vendor != other.vendor {
            return "Vetoed: vendors differ (\(vendor) vs \(other.vendor))"
        }
        if invoiceDate != other.invoiceDate {
            return "Vetoed: invoice dates differ (\(Self.dateString(invoiceDate)) vs \(Self.dateString(other.invoiceDate)))"
        }
        if let lhsNumber = invoiceNumber,
           let rhsNumber = other.invoiceNumber,
           lhsNumber != rhsNumber {
            return "Vetoed: invoice numbers differ (\(lhsNumber) vs \(rhsNumber))"
        }
        return nil
    }

    /// A hashable key for "possible same invoice" matching. Returns nil when the
    /// identity cannot participate (e.g. invoices without a number).
    var sameInvoiceKey: SameInvoiceKey? {
        switch documentType {
        case .invoice:
            guard let invoiceNumber else { return nil }
            return SameInvoiceKey(vendor: vendor, invoiceDate: invoiceDate, documentType: documentType, invoiceNumber: invoiceNumber)
        case .receipt:
            return SameInvoiceKey(vendor: vendor, invoiceDate: invoiceDate, documentType: documentType, invoiceNumber: nil)
        }
    }

    private static func normalizedField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func dateString(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return "unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

struct SameInvoiceKey: Hashable, Sendable {
    let vendor: String
    let invoiceDate: Date
    let documentType: DocumentType
    let invoiceNumber: String?
}
