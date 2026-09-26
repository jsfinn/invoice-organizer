import Foundation
import Testing

@testable import InvoiceOrganizer

/// Verification against a real diagnostic dump captured from an end user.
///
/// Dumps contain invoice OCR text, so none is committed. Point
/// `INVOICE_ORGANIZER_STATE_DUMP` at a dump on disk to run these; without it they
/// report their reason and pass, so CI stays green.
private func loadDump() throws -> LibraryStateDump? {
    guard let path = ProcessInfo.processInfo.environment["INVOICE_ORGANIZER_STATE_DUMP"] else {
        return nil
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(LibraryStateDump.self, from: data)
}

/// The similarity formula as it stood before per-document vectors were precomputed:
/// a set union per pair, with both magnitudes recomputed inside the pair loop.
private func referenceCosineSimilarity(
    lhs: [String: Int],
    rhs: [String: Int],
    documentFrequencies: [String: Int],
    documentCount: Int
) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else { return 0.0 }

    func idf(for term: String) -> Double {
        let df = Double(documentFrequencies[term] ?? 0)
        let n = Double(documentCount)
        return log((n + 1.0) / (df + 1.0)) + 1.0
    }

    let allTerms = Set(lhs.keys).union(rhs.keys)
    var dotProduct = 0.0
    var lhsMagnitudeSq = 0.0
    var rhsMagnitudeSq = 0.0

    for term in allTerms {
        let w = idf(for: term)
        let lhsWeight = Double(lhs[term] ?? 0) * w
        let rhsWeight = Double(rhs[term] ?? 0) * w
        dotProduct += lhsWeight * rhsWeight
        lhsMagnitudeSq += lhsWeight * lhsWeight
        rhsMagnitudeSq += rhsWeight * rhsWeight
    }

    let magnitude = (lhsMagnitudeSq * rhsMagnitudeSq).squareRoot()
    guard magnitude > 0 else { return 0.0 }
    return dotProduct / magnitude
}

// MARK: - Filename recovery

@Test func realDumpFilenameRecoveryOnlyFillsBlankFields() throws {
    guard let dump = try loadDump(), let computed = dump.computed else {
        print("skipped: set INVOICE_ORGANIZER_STATE_DUMP to a diagnostic dump")
        return
    }

    let processed = computed.artifacts.filter { $0.location == .processed }
    #expect(!processed.isEmpty)

    var unparsed: [String] = []
    var filledDates = 0
    var filledNumbers = 0
    var contradictions: [String] = []

    for artifact in processed {
        let fileURL = URL(fileURLWithPath: artifact.path)
        guard let parsed = ArchivePathBuilder.processedMetadata(from: fileURL) else {
            unparsed.append(fileURL.lastPathComponent)
            continue
        }

        let stored = DocumentMetadata(
            vendor: artifact.vendor,
            invoiceDate: artifact.invoiceDate,
            invoiceNumber: artifact.invoiceNumber,
            documentType: artifact.documentType
        )
        let hints = DocumentMetadata(
            vendor: parsed.vendor,
            invoiceDate: parsed.invoiceDate,
            invoiceNumber: parsed.invoiceNumber,
            documentType: nil
        )
        let merged = stored.fillingGaps(from: hints)

        // Nothing already populated may change. This is the property the release
        // depends on: recovery adds, it never rewrites.
        if let vendor = stored.vendor, merged.vendor != vendor {
            contradictions.append("\(fileURL.lastPathComponent): vendor \(vendor) -> \(merged.vendor ?? "nil")")
        }
        if let date = stored.invoiceDate, merged.invoiceDate != date {
            contradictions.append("\(fileURL.lastPathComponent): date changed")
        }
        if let number = stored.invoiceNumber, merged.invoiceNumber != number {
            contradictions.append("\(fileURL.lastPathComponent): number \(number) -> \(merged.invoiceNumber ?? "nil")")
        }

        if stored.invoiceDate == nil, merged.invoiceDate != nil { filledDates += 1 }
        if stored.invoiceNumber == nil, merged.invoiceNumber != nil { filledNumbers += 1 }
    }

    print("processed=\(processed.count) unparsed=\(unparsed.count) filledDates=\(filledDates) filledNumbers=\(filledNumbers)")
    #expect(unparsed.isEmpty, "unparsed filenames: \(unparsed.prefix(10))")
    #expect(contradictions.isEmpty, "\(contradictions.prefix(10))")
    #expect(filledDates > 0)
    #expect(filledNumbers > 0)
}

// MARK: - Duplicate detection

@Test func realDumpClustersAreUnchangedByVectorPrecomputation() throws {
    guard let dump = try loadDump() else {
        print("skipped: set INVOICE_ORGANIZER_STATE_DUMP to a diagnostic dump")
        return
    }

    let termFrequencies = DuplicateDetector.termFrequenciesFromRecords(dump.raw.extractedTextByContentHash)
    let corpus = Array(termFrequencies.values)
    guard corpus.count >= 2 else {
        print("skipped: dump has fewer than two extracted documents")
        return
    }

    let (documentFrequencies, documentCount) = DuplicateDetector.computeDocumentFrequencies(from: corpus)
    let vectors = corpus.map {
        DuplicateDetector.weightedVector(
            for: $0,
            documentFrequencies: documentFrequencies,
            documentCount: documentCount
        )
    }

    // Scores must agree with the pre-change formula to within floating-point
    // summation order, and in particular must never straddle the match threshold.
    var worstDelta = 0.0
    var straddles = 0
    var referenceElapsed = Duration.zero
    var vectorElapsed = Duration.zero

    for i in corpus.indices {
        for j in (i + 1)..<corpus.count {
            let referenceStart = ContinuousClock.now
            let expected = referenceCosineSimilarity(
                lhs: corpus[i],
                rhs: corpus[j],
                documentFrequencies: documentFrequencies,
                documentCount: documentCount
            )
            referenceElapsed += ContinuousClock.now - referenceStart

            let vectorStart = ContinuousClock.now
            let actual = DuplicateDetector.cosineSimilarity(lhs: vectors[i], rhs: vectors[j])
            vectorElapsed += ContinuousClock.now - vectorStart

            worstDelta = max(worstDelta, abs(expected - actual))

            let threshold = DuplicateDetector.textSimilarityThreshold
            if (expected >= threshold) != (actual >= threshold) { straddles += 1 }
        }
    }

    let pairCount = corpus.count * (corpus.count - 1) / 2
    print("compared \(pairCount) pairs, worst delta \(worstDelta)")
    print("pairwise cost: reference \(referenceElapsed) vs vectors \(vectorElapsed)")
    #expect(worstDelta < 1e-9, "similarity drifted by \(worstDelta)")
    #expect(straddles == 0, "\(straddles) pairs changed side of the match threshold")
}

@Test func realDumpClusteringCompletesQuickly() throws {
    guard let dump = try loadDump(), let computed = dump.computed else {
        print("skipped: set INVOICE_ORGANIZER_STATE_DUMP to a diagnostic dump")
        return
    }

    let files: [ScannedInvoiceFile] = computed.artifacts.map { artifact in
        let fileURL = URL(fileURLWithPath: artifact.path)
        return ScannedInvoiceFile(
            id: artifact.artifactID,
            name: fileURL.lastPathComponent,
            fileURL: fileURL,
            location: artifact.location,
            vendor: nil,
            invoiceDate: nil,
            processedAt: nil,
            addedAt: .now,
            fileType: fileURL.pathExtension.lowercased() == "pdf" ? .pdf : .image,
            contentHash: artifact.contentHash
        )
    }

    let separated = Set(dump.raw.separatedContentHashPairs)
    let start = ContinuousClock.now
    let clusters = DuplicateDetector.duplicateGroups(
        for: files,
        termFrequenciesByContentHash: DuplicateDetector.termFrequenciesFromRecords(dump.raw.extractedTextByContentHash),
        firstPageTermFrequenciesByContentHash: DuplicateDetector.firstPageTermFrequenciesFromRecords(dump.raw.extractedTextByContentHash),
        structuredRecordsByContentHash: dump.raw.structuredDataByContentHash,
        separatedContentHashPairs: separated
    )
    let elapsed = ContinuousClock.now - start

    let namesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.name) })
    for cluster in clusters {
        print("  group: \(cluster.artifactIDs.compactMap { namesByID[$0] })")
    }
    print("clustered \(files.count) artifacts into \(clusters.count) groups in \(elapsed)")
    // A single pass has to stay well under a frame budget's worth of stalling, since
    // the library rebuilds once per extracted document during a bulk import.
    #expect(elapsed < .seconds(1), "clustering took \(elapsed)")
}

/// The whole snapshot rebuild, which is what runs on the main actor and therefore
/// what the user experiences as a stall when files move between queues.
@Test func realDumpSnapshotRebuildStaysResponsive() throws {
    guard let dump = try loadDump(), let computed = dump.computed else {
        print("skipped: set INVOICE_ORGANIZER_STATE_DUMP to a diagnostic dump")
        return
    }

    let artifacts: [PhysicalArtifact] = computed.artifacts.map { artifact in
        let fileURL = URL(fileURLWithPath: artifact.path)
        return PhysicalArtifact(
            id: artifact.artifactID,
            name: fileURL.lastPathComponent,
            fileURL: fileURL,
            location: artifact.location,
            vendor: artifact.vendor,
            invoiceDate: artifact.invoiceDate,
            invoiceNumber: artifact.invoiceNumber,
            documentType: artifact.documentType,
            addedAt: .now,
            fileType: fileURL.pathExtension.lowercased() == "pdf" ? .pdf : .image,
            status: artifact.status,
            contentHash: artifact.contentHash
        )
    }

    let structuredByHash = dump.raw.structuredDataByContentHash
    let builder = LibrarySnapshotBuilder { structuredByHash[$0] }
    let workflows = dump.raw.workflowByArtifactID
    let termFrequencies = DuplicateDetector.termFrequenciesFromRecords(dump.raw.extractedTextByContentHash)
    let firstPageFrequencies = DuplicateDetector.firstPageTermFrequenciesFromRecords(dump.raw.extractedTextByContentHash)
    let separated = Set(dump.raw.separatedContentHashPairs)

    var timings: [Duration] = []
    for _ in 0..<5 {
        let start = ContinuousClock.now
        let snapshot = builder.build(
            from: artifacts,
            workflowsByArtifactID: workflows,
            documentMetadataHintsByArtifactID: [:],
            duplicateTermFrequenciesByHash: termFrequencies,
            duplicateFirstPageTermFrequenciesByHash: firstPageFrequencies,
            separatedContentHashPairs: separated
        )
        timings.append(ContinuousClock.now - start)
        #expect(snapshot.documents.count > 0)
    }

    let median = timings.sorted()[timings.count / 2]
    print("full snapshot rebuild over \(artifacts.count) artifacts: median \(median), all \(timings)")
    #expect(median < .seconds(1), "rebuild took \(median)")
}
