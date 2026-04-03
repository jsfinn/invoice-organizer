import Foundation

struct InvoiceDuplicateInfo: Equatable, Sendable {
    let duplicateOfPath: String
    let reason: String
}

enum InvoiceDuplicateDetector {
    private static let similarityThreshold = 0.9

    static func extractedTextDuplicateMap(
        for files: [ScannedInvoiceFile],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [String: InvoiceDuplicateInfo] {
        duplicateMap(
            candidates: files.map {
                DuplicateCandidate(
                    id: $0.id,
                    fileURL: $0.fileURL,
                    location: $0.location,
                    addedAt: $0.addedAt,
                    contentHash: $0.contentHash
                )
            },
            textRecordsByContentHash: textRecordsByContentHash
        )
    }

    static func extractedTextDuplicateMap(
        for invoices: [InvoiceItem],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [InvoiceItem.ID: InvoiceDuplicateInfo] {
        duplicateMap(
            candidates: invoices.map {
                DuplicateCandidate(
                    id: $0.id,
                    fileURL: $0.fileURL,
                    location: $0.location,
                    addedAt: $0.addedAt,
                    contentHash: $0.contentHash
                )
            },
            textRecordsByContentHash: textRecordsByContentHash
        )
    }

    private static func duplicateMap(
        candidates: [DuplicateCandidate],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [String: InvoiceDuplicateInfo] {
        let candidatesWithTokens = candidates.compactMap { candidate -> CandidateTextSignature? in
            guard let contentHash = candidate.contentHash,
                  let record = textRecordsByContentHash[contentHash],
                  let tokens = normalizedTokenSet(for: record.text),
                  !tokens.isEmpty else {
                return nil
            }
            return CandidateTextSignature(candidate: candidate, tokens: tokens)
        }

        let groups = buildSimilarityGroups(from: candidatesWithTokens)
        var duplicates: [String: InvoiceDuplicateInfo] = [:]

        for group in groups {
            guard group.count > 1 else { continue }

            guard let canonical = group.first?.candidate else { continue }

            for entry in group.dropFirst() where entry.candidate.location != .processed {
                duplicates[entry.candidate.id] = InvoiceDuplicateInfo(
                    duplicateOfPath: canonical.fileURL.path,
                    reason: "Similar extracted text matches \(canonical.fileURL.lastPathComponent)"
                )
            }
        }

        return duplicates
    }

    private static func buildSimilarityGroups(from candidates: [CandidateTextSignature]) -> [[CandidateTextSignature]] {
        let sortedCandidates = candidates.sorted { duplicatePriority(lhs: $0.candidate, rhs: $1.candidate) }
        var groups: [[CandidateTextSignature]] = []

        for candidate in sortedCandidates {
            if let matchIndex = groups.firstIndex(where: { group in
                guard let canonical = group.first else { return false }
                return jaccardSimilarity(candidate.tokens, canonical.tokens) >= similarityThreshold
            }) {
                groups[matchIndex].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups
    }

    static func normalizedTokenSet(for text: String) -> Set<String>? {
        guard let normalizedText = DocumentTextExtractor.normalizeText(text) else { return nil }

        let lowercased = normalizedText.lowercased()
        let cleaned = lowercased.replacingOccurrences(
            of: "[^a-z0-9\\s]",
            with: " ",
            options: .regularExpression
        )
        let tokens = Set(cleaned.split(whereSeparator: \.isWhitespace).map(String.init))
        return tokens.isEmpty ? nil : tokens
    }

    static func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 1.0 }
        let intersection = lhs.intersection(rhs)
        return Double(intersection.count) / Double(union.count)
    }

    private static func duplicatePriority(lhs: DuplicateCandidate, rhs: DuplicateCandidate) -> Bool {
        let lhsPriority = lhs.location == .processed ? 0 : 1
        let rhsPriority = rhs.location == .processed ? 0 : 1

        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if lhs.addedAt != rhs.addedAt {
            return lhs.addedAt < rhs.addedAt
        }

        return lhs.id < rhs.id
    }
}

private struct DuplicateCandidate: Sendable {
    let id: String
    let fileURL: URL
    let location: InvoiceLocation
    let addedAt: Date
    let contentHash: String?
}

private struct CandidateTextSignature: Sendable {
    let candidate: DuplicateCandidate
    let tokens: Set<String>
}
