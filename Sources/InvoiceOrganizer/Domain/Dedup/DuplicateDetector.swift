import Foundation

enum DuplicateDetector {
    static let textSimilarityThreshold: Double = 0.85

    // MARK: - Convenience entry points (ScannedInvoiceFile)

    static func duplicateGroups(
        for files: [ScannedInvoiceFile],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [ArtifactDuplicateCluster] {
        duplicateGroups(
            for: files,
            termFrequenciesByContentHash: termFrequenciesFromRecords(textRecordsByContentHash),
            firstPageTermFrequenciesByContentHash: firstPageTermFrequenciesFromRecords(textRecordsByContentHash)
        )
    }

    static func duplicateGroups(
        for files: [ScannedInvoiceFile],
        termFrequenciesByContentHash: [String: [String: Int]],
        firstPageTermFrequenciesByContentHash: [String: [String: Int]] = [:],
        structuredRecordsByContentHash: [String: InvoiceStructuredDataRecord] = [:],
        separatedContentHashPairs: Set<ContentHashPair> = []
    ) -> [ArtifactDuplicateCluster] {
        buildClusters(
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
            termFrequenciesByContentHash: termFrequenciesByContentHash,
            firstPageTermFrequenciesByContentHash: firstPageTermFrequenciesByContentHash,
            structuredRecordsByContentHash: structuredRecordsByContentHash,
            separatedContentHashPairs: separatedContentHashPairs
        )
    }

    // MARK: - Convenience entry points (PhysicalArtifact)

    static func duplicateGroups(
        for invoices: [PhysicalArtifact],
        textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [ArtifactDuplicateCluster] {
        duplicateGroups(
            for: invoices,
            termFrequenciesByContentHash: termFrequenciesFromRecords(textRecordsByContentHash),
            firstPageTermFrequenciesByContentHash: firstPageTermFrequenciesFromRecords(textRecordsByContentHash)
        )
    }

    static func duplicateGroups(
        for invoices: [PhysicalArtifact],
        termFrequenciesByContentHash: [String: [String: Int]],
        firstPageTermFrequenciesByContentHash: [String: [String: Int]] = [:],
        structuredRecordsByContentHash: [String: InvoiceStructuredDataRecord] = [:],
        separatedContentHashPairs: Set<ContentHashPair> = []
    ) -> [ArtifactDuplicateCluster] {
        buildClusters(
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
            termFrequenciesByContentHash: termFrequenciesByContentHash,
            firstPageTermFrequenciesByContentHash: firstPageTermFrequenciesByContentHash,
            structuredRecordsByContentHash: structuredRecordsByContentHash,
            separatedContentHashPairs: separatedContentHashPairs
        )
    }

    // MARK: - Text Processing

    static func normalizedTermFrequencies(for text: String?) -> [String: Int]? {
        guard let normalizedText = DocumentTextExtractor.normalizeText(text) else { return nil }

        let lowercased = normalizedText.lowercased()
        let cleaned = lowercased.replacingOccurrences(
            of: "[^a-z0-9\\s]",
            with: " ",
            options: .regularExpression
        )
        var frequencies: [String: Int] = [:]
        for token in cleaned.split(whereSeparator: \.isWhitespace) {
            frequencies[String(token), default: 0] += 1
        }
        return frequencies.isEmpty ? nil : frequencies
    }

    static func termFrequenciesFromRecords(
        _ textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [String: [String: Int]] {
        Dictionary(
            uniqueKeysWithValues: textRecordsByContentHash.compactMap { contentHash, record in
                guard let freqs = normalizedTermFrequencies(for: record.text), !freqs.isEmpty else {
                    return nil
                }
                return (contentHash, freqs)
            }
        )
    }

    static func firstPageTermFrequenciesFromRecords(
        _ textRecordsByContentHash: [String: InvoiceTextRecord]
    ) -> [String: [String: Int]] {
        Dictionary(
            uniqueKeysWithValues: textRecordsByContentHash.compactMap { contentHash, record in
                guard let freqs = normalizedTermFrequencies(for: record.firstPageText), !freqs.isEmpty else {
                    return nil
                }
                return (contentHash, freqs)
            }
        )
    }

    // MARK: - TF-IDF Cosine Similarity

    static func computeDocumentFrequencies(
        from allTermFrequencies: [[String: Int]]
    ) -> (frequencies: [String: Int], documentCount: Int) {
        var df: [String: Int] = [:]
        for docFreqs in allTermFrequencies {
            for term in docFreqs.keys {
                df[term, default: 0] += 1
            }
        }
        return (df, allTermFrequencies.count)
    }

    /// A document's TF-IDF weights with its magnitude already folded in.
    ///
    /// A document's magnitude does not depend on what it is being compared against,
    /// and the dot product only draws on terms the two documents share. Computing the
    /// magnitude once per document therefore lets each pair walk the term
    /// intersection (mean 27 on the reference corpus) rather than the union (mean
    /// 297), which is where the pairwise pass spends nearly all of its time.
    struct WeightedDocumentVector: Sendable {
        let weights: [String: Double]
        let magnitude: Double

        var isEmpty: Bool { weights.isEmpty }
    }

    static func weightedVector(
        for termFrequencies: [String: Int],
        documentFrequencies: [String: Int],
        documentCount: Int
    ) -> WeightedDocumentVector {
        let n = Double(documentCount)
        var weights: [String: Double] = Dictionary(minimumCapacity: termFrequencies.count)
        var magnitudeSq = 0.0

        for (term, frequency) in termFrequencies {
            let df = Double(documentFrequencies[term] ?? 0)
            let weight = Double(frequency) * (log((n + 1.0) / (df + 1.0)) + 1.0)
            weights[term] = weight
            magnitudeSq += weight * weight
        }

        return WeightedDocumentVector(weights: weights, magnitude: magnitudeSq.squareRoot())
    }

    static func cosineSimilarity(lhs: WeightedDocumentVector, rhs: WeightedDocumentVector) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0.0 }

        let magnitude = lhs.magnitude * rhs.magnitude
        guard magnitude > 0 else { return 0.0 }

        // Probing the larger dictionary with the smaller one's keys keeps the loop
        // bounded by the smaller document.
        let (probe, table) = lhs.weights.count <= rhs.weights.count
            ? (lhs.weights, rhs.weights)
            : (rhs.weights, lhs.weights)

        var dotProduct = 0.0
        for (term, weight) in probe {
            guard let otherWeight = table[term] else { continue }
            dotProduct += weight * otherWeight
        }

        return dotProduct / magnitude
    }

    /// Convenience for one-off comparisons where no vectors have been built yet.
    /// Pairwise passes should build the vectors once and use the overload above.
    static func cosineSimilarity(
        lhs: [String: Int],
        rhs: [String: Int],
        documentFrequencies: [String: Int],
        documentCount: Int
    ) -> Double {
        cosineSimilarity(
            lhs: weightedVector(for: lhs, documentFrequencies: documentFrequencies, documentCount: documentCount),
            rhs: weightedVector(for: rhs, documentFrequencies: documentFrequencies, documentCount: documentCount)
        )
    }

    // MARK: - Veto / Debug

    static func structuredVetoReason(
        between lhs: InvoiceStructuredDataRecord?,
        and rhs: InvoiceStructuredDataRecord?
    ) -> String? {
        guard let lhs, let rhs,
              let lhsIdentity = DocumentIdentity(record: lhs),
              let rhsIdentity = DocumentIdentity(record: rhs) else {
            return nil
        }
        return lhsIdentity.conflictReason(with: rhsIdentity)
    }

    static func structuredPendingReason(
        lhsRecord: InvoiceStructuredDataRecord?,
        rhsRecord: InvoiceStructuredDataRecord?
    ) -> String? {
        let lhsHas = lhsRecord != nil
        let rhsHas = rhsRecord != nil
        if lhsHas != rhsHas {
            return "Structured comparison pending (one file not yet extracted)"
        }
        return nil
    }

    // MARK: - Constrained Union-Find Clustering

    private static func buildClusters(
        candidates: [DuplicateCandidate],
        termFrequenciesByContentHash: [String: [String: Int]],
        firstPageTermFrequenciesByContentHash: [String: [String: Int]],
        structuredRecordsByContentHash: [String: InvoiceStructuredDataRecord],
        separatedContentHashPairs: Set<ContentHashPair> = []
    ) -> [ArtifactDuplicateCluster] {
        let identitiesByContentHash: [String: DocumentIdentity] = Dictionary(
            uniqueKeysWithValues: structuredRecordsByContentHash.compactMap { hash, record in
                guard let identity = DocumentIdentity(record: record) else { return nil }
                return (hash, identity)
            }
        )

        struct EnrichedCandidate {
            let candidate: DuplicateCandidate
            let termFrequencies: [String: Int]?
            let firstPageTermFrequencies: [String: Int]?
            let identity: DocumentIdentity?
        }

        let enriched = candidates.map { c in
            let hash = c.contentHash
            return EnrichedCandidate(
                candidate: c,
                termFrequencies: hash.flatMap { termFrequenciesByContentHash[$0] },
                firstPageTermFrequencies: hash.flatMap { firstPageTermFrequenciesByContentHash[$0] },
                identity: hash.flatMap { identitiesByContentHash[$0] }
            )
        }

        let uf = UnionFind()
        for e in enriched { uf.makeSet(e.candidate.id) }

        var identitiesByRoot: [String: [DocumentIdentity]] = [:]
        for e in enriched {
            if let identity = e.identity {
                identitiesByRoot[e.candidate.id, default: []].append(identity)
            }
        }

        // Track the set of content hashes living under each root so user-declared
        // "not a duplicate" overrides can be enforced even through transitive matches.
        var contentHashesByRoot: [String: Set<String>] = [:]
        if !separatedContentHashPairs.isEmpty {
            for e in enriched {
                if let hash = e.candidate.contentHash {
                    contentHashesByRoot[e.candidate.id, default: []].insert(hash)
                }
            }
        }

        func isSeparated(_ hashesA: Set<String>, _ hashesB: Set<String>) -> Bool {
            guard !separatedContentHashPairs.isEmpty else { return false }
            for ha in hashesA {
                for hb in hashesB where separatedContentHashPairs.contains(ContentHashPair(ha, hb)) {
                    return true
                }
            }
            return false
        }

        func canMerge(_ a: String, _ b: String) -> Bool {
            let rootA = uf.find(a)
            let rootB = uf.find(b)
            guard rootA != rootB else { return true }

            if isSeparated(contentHashesByRoot[rootA] ?? [], contentHashesByRoot[rootB] ?? []) {
                return false
            }

            let idsA = identitiesByRoot[rootA] ?? []
            let idsB = identitiesByRoot[rootB] ?? []
            for idA in idsA {
                for idB in idsB {
                    if idA.conflicts(with: idB) { return false }
                }
            }
            return true
        }

        func doUnion(_ a: String, _ b: String) {
            let rootA = uf.find(a)
            let rootB = uf.find(b)
            guard rootA != rootB else { return }
            let idsA = identitiesByRoot.removeValue(forKey: rootA) ?? []
            let idsB = identitiesByRoot.removeValue(forKey: rootB) ?? []
            let hashesA = contentHashesByRoot.removeValue(forKey: rootA) ?? []
            let hashesB = contentHashesByRoot.removeValue(forKey: rootB) ?? []
            uf.union(a, b)
            let newRoot = uf.find(a)
            identitiesByRoot[newRoot] = idsA + idsB
            if !hashesA.isEmpty || !hashesB.isEmpty {
                contentHashesByRoot[newRoot] = hashesA.union(hashesB)
            }
        }

        // Step 1: Union identical files (same contentHash)
        var byHash: [String: [EnrichedCandidate]] = [:]
        for e in enriched {
            guard let hash = e.candidate.contentHash else { continue }
            byHash[hash, default: []].append(e)
        }
        for (_, group) in byHash where group.count > 1 {
            let firstID = group[0].candidate.id
            for e in group.dropFirst() {
                doUnion(firstID, e.candidate.id)
            }
        }

        // Step 2: Union structurally-matched pairs (isPositiveMatch)
        let withIdentity = enriched.filter { $0.identity != nil }
        for i in withIdentity.indices {
            for j in (i + 1)..<withIdentity.count {
                if withIdentity[i].identity!.isPositiveMatch(withIdentity[j].identity!) {
                    if canMerge(withIdentity[i].candidate.id, withIdentity[j].candidate.id) {
                        doUnion(withIdentity[i].candidate.id, withIdentity[j].candidate.id)
                    }
                }
            }
        }

        // Step 3: Compute text similarity and union above threshold (respecting conflicts)
        let withText = enriched.filter { $0.termFrequencies != nil }
        guard withText.count >= 2 else {
            return clustersFromUnionFind(uf, candidates: enriched.map(\.candidate))
        }

        let allDocFreqs = withText.compactMap(\.termFrequencies)
        let (documentFrequencies, documentCount) = computeDocumentFrequencies(from: allDocFreqs)

        let firstPageFreqs = withText.compactMap(\.firstPageTermFrequencies)
        let fpDF: [String: Int]
        let fpDC: Int
        if !firstPageFreqs.isEmpty {
            let result = computeDocumentFrequencies(from: firstPageFreqs)
            fpDF = result.frequencies
            fpDC = result.documentCount
        } else {
            fpDF = [:]
            fpDC = 0
        }

        struct ScoredEdge: Comparable {
            let i: Int
            let j: Int
            let score: Double
            static func < (lhs: ScoredEdge, rhs: ScoredEdge) -> Bool { lhs.score > rhs.score }
        }

        let vectors = withText.map {
            weightedVector(
                for: $0.termFrequencies!,
                documentFrequencies: documentFrequencies,
                documentCount: documentCount
            )
        }
        let firstPageVectors = withText.map { entry in
            entry.firstPageTermFrequencies.map {
                weightedVector(for: $0, documentFrequencies: fpDF, documentCount: fpDC)
            }
        }

        var edges: [ScoredEdge] = []
        for i in withText.indices {
            for j in (i + 1)..<withText.count {
                var score = cosineSimilarity(lhs: vectors[i], rhs: vectors[j])

                // First-page fallback: if both have first-page data and have a matching
                // identity, use the higher of whole-doc and first-page scores
                if let lhsFP = firstPageVectors[i],
                   let rhsFP = firstPageVectors[j],
                   withText[i].identity != nil,
                   withText[j].identity != nil,
                   !withText[i].identity!.conflicts(with: withText[j].identity!) {
                    score = max(score, cosineSimilarity(lhs: lhsFP, rhs: rhsFP))
                }

                if score >= textSimilarityThreshold {
                    edges.append(ScoredEdge(i: i, j: j, score: score))
                }
            }
        }
        edges.sort()

        for edge in edges {
            let idA = withText[edge.i].candidate.id
            let idB = withText[edge.j].candidate.id
            if canMerge(idA, idB) {
                doUnion(idA, idB)
            }
        }

        return clustersFromUnionFind(uf, candidates: enriched.map(\.candidate))
    }

    private static func clustersFromUnionFind(
        _ uf: UnionFind,
        candidates: [DuplicateCandidate]
    ) -> [ArtifactDuplicateCluster] {
        var groups: [String: [DuplicateCandidate]] = [:]
        for candidate in candidates {
            let root = uf.find(candidate.id)
            groups[root, default: []].append(candidate)
        }

        return groups.values
            .filter { $0.count > 1 }
            .map { group in
                let sorted = group.sorted(by: duplicatePriority)
                return ArtifactDuplicateCluster(artifactIDs: sorted.map(\.id))
            }
    }

    private static func duplicatePriority(lhs: DuplicateCandidate, rhs: DuplicateCandidate) -> Bool {
        let lhsPriority = lhs.location == .processed ? 0 : 1
        let rhsPriority = rhs.location == .processed ? 0 : 1
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

        let lhsJPEGPriority = lhs.fileType == .jpeg ? 0 : 1
        let rhsJPEGPriority = rhs.fileType == .jpeg ? 0 : 1
        if lhsJPEGPriority != rhsJPEGPriority { return lhsJPEGPriority < rhsJPEGPriority }

        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.id < rhs.id
    }
}

// MARK: - Internal Types

private struct DuplicateCandidate: Sendable {
    let id: String
    let fileURL: URL
    let location: InvoiceLocation
    let addedAt: Date
    let fileType: InvoiceFileType
    let contentHash: String?
}

private final class UnionFind {
    private var parent: [String: String] = [:]
    private var rank: [String: Int] = [:]

    func makeSet(_ x: String) {
        guard parent[x] == nil else { return }
        parent[x] = x
        rank[x] = 0
    }

    func find(_ x: String) -> String {
        guard let p = parent[x] else { return x }
        if p != x {
            parent[x] = find(p)
        }
        return parent[x]!
    }

    func union(_ x: String, _ y: String) {
        let rootX = find(x)
        let rootY = find(y)
        guard rootX != rootY else { return }

        let rankX = rank[rootX] ?? 0
        let rankY = rank[rootY] ?? 0
        if rankX < rankY {
            parent[rootX] = rootY
        } else if rankX > rankY {
            parent[rootY] = rootX
        } else {
            parent[rootY] = rootX
            rank[rootX] = rankX + 1
        }
    }
}
