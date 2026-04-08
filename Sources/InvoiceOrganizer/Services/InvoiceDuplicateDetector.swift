import Foundation

enum InvoiceDuplicateDetector {
    private static let similarityThreshold = 0.9

    static var duplicateSimilarityThreshold: Double {
        similarityThreshold
    }

    static func extractedTextDuplicateGroups(
        for files: [ScannedInvoiceFile],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [InvoiceDuplicateGroup] {
        extractedTextDuplicateGroups(
            for: files,
            tokenSetsByContentHash: normalizedTokenSets(from: textRecordsByContentHash)
        )
    }

    static func extractedTextDuplicateGroups(
        for files: [ScannedInvoiceFile],
        tokenSetsByContentHash: [String: Set<String>]
    ) -> [InvoiceDuplicateGroup] {
        duplicateGroups(
            candidates: files.map {
                DuplicateCandidate(
                    id: $0.id,
                    fileURL: $0.fileURL,
                    location: $0.location,
                    addedAt: $0.addedAt,
                    fileType: $0.fileType,
                    contentHash: $0.contentHash
                )
            },
            tokenSetsByContentHash: tokenSetsByContentHash
        )
    }

    static func extractedTextDuplicateGroups(
        for invoices: [PhysicalArtifact],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [InvoiceDuplicateGroup] {
        extractedTextDuplicateGroups(
            for: invoices,
            tokenSetsByContentHash: normalizedTokenSets(from: textRecordsByContentHash)
        )
    }

    static func extractedTextDuplicateGroups(
        for invoices: [PhysicalArtifact],
        tokenSetsByContentHash: [String: Set<String>]
    ) -> [InvoiceDuplicateGroup] {
        duplicateGroups(
            candidates: invoices.map {
                DuplicateCandidate(
                    id: $0.id,
                    fileURL: $0.fileURL,
                    location: $0.location,
                    addedAt: $0.addedAt,
                    fileType: $0.fileType,
                    contentHash: $0.contentHash
                )
            },
            tokenSetsByContentHash: tokenSetsByContentHash
        )
    }

    static func extractedTextDuplicateMap(
        for files: [ScannedInvoiceFile],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [String: InvoiceDuplicateInfo] {
        duplicateMap(
            groups: extractedTextDuplicateGroups(
                for: files,
                textRecordsByContentHash: textRecordsByContentHash
            )
        )
    }

    static func extractedTextDuplicateMap(
        for invoices: [PhysicalArtifact],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [PhysicalArtifact.ID: InvoiceDuplicateInfo] {
        duplicateMap(
            groups: extractedTextDuplicateGroups(
                for: invoices,
                textRecordsByContentHash: textRecordsByContentHash
            )
        )
    }

    private static func duplicateGroups(
        candidates: [DuplicateCandidate],
        tokenSetsByContentHash: [String: Set<String>]
    ) -> [InvoiceDuplicateGroup] {
        let candidatesWithTokens = candidates.compactMap { candidate -> CandidateTextSignature? in
            guard let contentHash = candidate.contentHash,
                  let tokens = tokenSetsByContentHash[contentHash],
                  !tokens.isEmpty else {
                return nil
            }
            return CandidateTextSignature(candidate: candidate, tokens: tokens)
        }

        return buildSimilarityGroups(from: candidatesWithTokens)
            .filter { $0.count > 1 }
            .map { group in
                InvoiceDuplicateGroup(
                    members: group.map {
                        InvoiceDuplicateMember(
                            id: $0.candidate.id,
                            fileURL: $0.candidate.fileURL,
                            location: $0.candidate.location,
                            addedAt: $0.candidate.addedAt,
                            fileType: $0.candidate.fileType
                        )
                    }
                )
            }
    }

    private static func duplicateMap(
        groups: [InvoiceDuplicateGroup]
    ) -> [String: InvoiceDuplicateInfo] {
        var duplicates: [String: InvoiceDuplicateInfo] = [:]

        for group in groups {
            for member in group.members where group.isSoftBlocked(memberID: member.id) {
                guard let duplicateInfo = group.duplicateInfo(for: member.id) else { continue }
                duplicates[member.id] = duplicateInfo
            }
        }

        return duplicates
    }

    private static func buildSimilarityGroups(from candidates: [CandidateTextSignature]) -> [[CandidateTextSignature]] {
        let sortedCandidates = candidates.sorted { duplicatePriority(lhs: $0.candidate, rhs: $1.candidate) }
        var groups: [[CandidateTextSignature]] = []

        for candidate in sortedCandidates {
            if let matchIndex = bestMatchingGroupIndex(for: candidate, in: groups) {
                groups[matchIndex].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups
    }

    static func normalizedTokenSets(from textRecordsByContentHash: [String: InvoiceTextRecord]) -> [String: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: textRecordsByContentHash.compactMap { contentHash, record in
                guard let tokens = normalizedTokenSet(for: record.text), !tokens.isEmpty else {
                    return nil
                }

                return (contentHash, tokens)
            }
        )
    }

    private static func bestMatchingGroupIndex(
        for candidate: CandidateTextSignature,
        in groups: [[CandidateTextSignature]]
    ) -> Int? {
        var bestIndex: Int?
        var bestScore = 0.0

        for (index, group) in groups.enumerated() {
            let groupBestScore = group.reduce(0.0) { currentBest, member in
                max(currentBest, jaccardSimilarity(candidate.tokens, member.tokens))
            }

            guard groupBestScore >= similarityThreshold else { continue }

            if groupBestScore > bestScore {
                bestScore = groupBestScore
                bestIndex = index
            }
        }

        return bestIndex
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
}

private struct DuplicateCandidate: Sendable {
    let id: String
    let fileURL: URL
    let location: InvoiceLocation
    let addedAt: Date
    let fileType: InvoiceFileType
    let contentHash: String?
}

private struct CandidateTextSignature: Sendable {
    let candidate: DuplicateCandidate
    let tokens: Set<String>
}
