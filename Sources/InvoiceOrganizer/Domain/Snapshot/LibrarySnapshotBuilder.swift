import Foundation

struct LibrarySnapshot {
    let artifacts: [PhysicalArtifact]
    let documents: [Document]
    let documentsByID: [Document.ID: Document]
    let documentsByArtifactID: [PhysicalArtifact.ID: Document]
    let documentMetadataByArtifactID: [PhysicalArtifact.ID: DocumentMetadata]
    let duplicateTokenSetsByArtifactID: [PhysicalArtifact.ID: Set<String>]
    let possibleSameInvoiceMatchesByArtifactID: [PhysicalArtifact.ID: [PossibleSameInvoiceMatch]]

    static let empty = LibrarySnapshot(
        artifacts: [],
        documents: [],
        documentsByID: [:],
        documentsByArtifactID: [:],
        documentMetadataByArtifactID: [:],
        duplicateTokenSetsByArtifactID: [:],
        possibleSameInvoiceMatchesByArtifactID: [:]
    )

    func document(for artifactID: PhysicalArtifact.ID) -> Document? {
        documentsByArtifactID[artifactID]
    }

    func metadata(for artifactID: PhysicalArtifact.ID) -> DocumentMetadata {
        documentMetadataByArtifactID[artifactID] ?? .empty
    }
}

struct LibrarySnapshotBuilder {
    var structuredRecordForContentHash: (String) -> InvoiceStructuredDataRecord?

    func build(
        from artifacts: [PhysicalArtifact],
        workflowsByArtifactID: [PhysicalArtifact.ID: StoredInvoiceWorkflow],
        documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata],
        duplicateTokensByHash: [String: Set<String>],
        duplicateFirstPageTokensByHash: [String: Set<String>]
    ) -> LibrarySnapshot {
        let structuredRecordsByHash: [String: InvoiceStructuredDataRecord] = artifacts.reduce(into: [:]) { recordsByHash, artifact in
            guard let contentHash = artifact.contentHash,
                  recordsByHash[contentHash] == nil,
                  let record = structuredRecordForContentHash(contentHash) else {
                return
            }

            recordsByHash[contentHash] = record
        }
        let duplicateClusters = DuplicateDetector.extractedTextDuplicateGroups(
            for: artifacts,
            tokenSetsByContentHash: duplicateTokensByHash,
            firstPageTokenSetsByContentHash: duplicateFirstPageTokensByHash,
            structuredRecordsByContentHash: structuredRecordsByHash
        )
        let documents = buildDocuments(
            from: artifacts,
            duplicateClusters: duplicateClusters,
            workflowsByArtifactID: workflowsByArtifactID,
            documentMetadataHintsByArtifactID: documentMetadataHintsByArtifactID
        )
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let documentsByArtifactID = Dictionary(
            uniqueKeysWithValues: documents.flatMap { document in
                document.artifactIDs.map { ($0, document) }
            }
        )
        let possibleSameInvoiceMatchesByArtifactID = buildPossibleSameInvoiceMatches(from: documents)

        var projectedArtifacts = artifacts
        var metadataByArtifactID: [PhysicalArtifact.ID: DocumentMetadata] = [:]
        for index in projectedArtifacts.indices {
            let artifactID = projectedArtifacts[index].id
            let document = documentsByArtifactID[artifactID]
            projectedArtifacts[index].documentID = document?.id ?? artifactID
            metadataByArtifactID[artifactID] = document?.metadata ?? documentMetadataHintsByArtifactID[artifactID] ?? .empty

            if let duplicateInfo = document?.duplicateInfo(forArtifactID: artifactID) {
                projectedArtifacts[index].status = .blockedDuplicate
                projectedArtifacts[index].duplicateOfPath = duplicateInfo.duplicateOfPath
                projectedArtifacts[index].duplicateReason = duplicateInfo.reason
            } else {
                projectedArtifacts[index].status = baseStatus(for: projectedArtifacts[index].location)
                projectedArtifacts[index].duplicateOfPath = nil
                projectedArtifacts[index].duplicateReason = nil
            }
        }

        let duplicateTokenSetsByArtifactID: [PhysicalArtifact.ID: Set<String>] = Dictionary(
            uniqueKeysWithValues: projectedArtifacts.compactMap { artifact in
                guard let contentHash = artifact.contentHash,
                      let tokens = duplicateTokensByHash[contentHash] else {
                    return nil
                }

                return (artifact.id, tokens)
            }
        )

        return LibrarySnapshot(
            artifacts: projectedArtifacts,
            documents: documents,
            documentsByID: documentsByID,
            documentsByArtifactID: documentsByArtifactID,
            documentMetadataByArtifactID: metadataByArtifactID,
            duplicateTokenSetsByArtifactID: duplicateTokenSetsByArtifactID,
            possibleSameInvoiceMatchesByArtifactID: possibleSameInvoiceMatchesByArtifactID
        )
    }

    func mergedDocumentMetadata(
        for artifactIDs: Set<PhysicalArtifact.ID>,
        artifacts: [PhysicalArtifact]
    ) -> DocumentMetadata {
        let records = artifacts
            .filter { artifactIDs.contains($0.id) }
            .compactMap { artifact -> InvoiceStructuredDataRecord? in
                guard let contentHash = artifact.contentHash else { return nil }
                return structuredRecordForContentHash(contentHash)
            }

        return DocumentMetadata(
            vendor: mergedStructuredValue(records.map(\.companyName)),
            invoiceDate: mergedStructuredValue(records.map(\.invoiceDate)),
            invoiceNumber: normalizedInvoiceNumber(from: mergedStructuredValue(records.map(\.invoiceNumber)) ?? ""),
            documentType: mergedStructuredValue(records.map(\.documentType))
        )
    }

    func inferredStructuredDocumentMetadata(for document: Document) -> DocumentMetadata? {
        inferredStructuredDocumentMetadata(for: document.artifacts)
    }

    private func buildDocuments(
        from artifacts: [PhysicalArtifact],
        duplicateClusters: [ArtifactDuplicateCluster],
        workflowsByArtifactID: [PhysicalArtifact.ID: StoredInvoiceWorkflow],
        documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata]
    ) -> [Document] {
        let artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        var documents: [Document] = []
        var groupedArtifactIDs: Set<PhysicalArtifact.ID> = []

        for cluster in duplicateClusters {
            let documentArtifacts = cluster.artifactIDs.compactMap { artifactID -> DocumentArtifactReference? in
                guard let artifact = artifactsByID[artifactID] else { return nil }
                return makeDocumentArtifactReference(from: artifact)
            }
            guard documentArtifacts.count > 1 else { continue }

            groupedArtifactIDs.formUnion(documentArtifacts.map(\.id))
            documents.append(
                Document(
                    artifacts: documentArtifacts,
                    metadata: resolvedDocumentMetadata(
                        for: documentArtifacts,
                        workflowsByArtifactID: workflowsByArtifactID,
                        documentMetadataHintsByArtifactID: documentMetadataHintsByArtifactID
                    )
                )
            )
        }

        for artifact in artifacts where !groupedArtifactIDs.contains(artifact.id) {
            let documentArtifact = makeDocumentArtifactReference(from: artifact)
            documents.append(
                Document(
                    artifacts: [documentArtifact],
                    metadata: resolvedDocumentMetadata(
                        for: [documentArtifact],
                        workflowsByArtifactID: workflowsByArtifactID,
                        documentMetadataHintsByArtifactID: documentMetadataHintsByArtifactID
                    )
                )
            )
        }

        return documents.sorted { lhs, rhs in
            let lhsDate = lhs.artifacts.map(\.addedAt).max() ?? .distantPast
            let rhsDate = rhs.artifacts.map(\.addedAt).max() ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            return lhs.id < rhs.id
        }
    }

    private func makeDocumentArtifactReference(from artifact: PhysicalArtifact) -> DocumentArtifactReference {
        DocumentArtifactReference(
            id: artifact.id,
            fileURL: artifact.fileURL,
            location: artifact.location,
            addedAt: artifact.addedAt,
            modifiedAt: artifact.modifiedAt,
            fileType: artifact.fileType,
            contentHash: artifact.contentHash
        )
    }

    private func resolvedDocumentMetadata(
        for artifacts: [DocumentArtifactReference],
        workflowsByArtifactID: [PhysicalArtifact.ID: StoredInvoiceWorkflow],
        documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata]
    ) -> DocumentMetadata {
        if artifacts.count == 1, let artifact = artifacts.first {
            return singletonDocumentMetadata(
                for: artifact,
                workflowsByArtifactID: workflowsByArtifactID,
                documentMetadataHintsByArtifactID: documentMetadataHintsByArtifactID
            )
        }

        let workflowMetadata = sharedDuplicateDocumentMetadata(
            for: artifacts,
            workflowsByArtifactID: workflowsByArtifactID
        )
        guard workflowMetadata.isEmpty else {
            return workflowMetadata
        }

        return inferredStructuredDocumentMetadata(for: artifacts) ?? .empty
    }

    private func singletonDocumentMetadata(
        for artifact: DocumentArtifactReference,
        workflowsByArtifactID: [PhysicalArtifact.ID: StoredInvoiceWorkflow],
        documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata]
    ) -> DocumentMetadata {
        if let workflow = workflowsByArtifactID[artifact.id] {
            return DocumentMetadata(workflow: workflow)
        }

        return documentMetadataHintsByArtifactID[artifact.id] ?? .empty
    }

    private func sharedDuplicateDocumentMetadata(
        for artifacts: [DocumentArtifactReference],
        workflowsByArtifactID: [PhysicalArtifact.ID: StoredInvoiceWorkflow]
    ) -> DocumentMetadata {
        let workflows = artifacts.compactMap { workflowsByArtifactID[$0.id] }
        guard workflows.count == artifacts.count,
              workflows.allSatisfy({ $0.metadataScope == .document }) else {
            return .empty
        }

        let metadata = workflows.map(DocumentMetadata.init(workflow:))
        guard let first = metadata.first,
              metadata.dropFirst().allSatisfy({ $0 == first }) else {
            return .empty
        }

        return first
    }

    private func inferredStructuredDocumentMetadata(for artifacts: [DocumentArtifactReference]) -> DocumentMetadata? {
        let contentHashes = artifacts.compactMap(\.contentHash)
        guard contentHashes.count == artifacts.count,
              contentHashes.allSatisfy({ structuredRecordForContentHash($0) != nil }) else {
            return nil
        }

        return mergedDocumentMetadata(for: Set(artifacts.map(\.id)), artifacts: artifacts.map(PhysicalArtifact.init(reference:)))
    }

    private func baseStatus(for location: InvoiceLocation) -> InvoiceStatus {
        switch location {
        case .inbox:
            return .unprocessed
        case .processing:
            return .inProgress
        case .processed:
            return .processed
        }
    }

    private func mergedStructuredValue<T: Hashable>(_ values: [T?]) -> T? {
        let uniqueValues = Set(values.compactMap { $0 })
        guard uniqueValues.count == 1 else { return nil }
        return uniqueValues.first
    }

    private func normalizedInvoiceNumber(from invoiceNumber: String) -> String? {
        let trimmed = invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func buildPossibleSameInvoiceMatches(
        from documents: [Document]
    ) -> [PhysicalArtifact.ID: [PossibleSameInvoiceMatch]] {
        let candidateDocuments = documents.compactMap { document -> (Document, DocumentMetadata, SameInvoiceSignature)? in
            let effectiveMetadata = sameInvoiceMetadata(for: document)
            guard let signature = SameInvoiceSignature(metadata: effectiveMetadata) else {
                return nil
            }

            return (document, effectiveMetadata, signature)
        }
        let documentsBySignature = Dictionary(grouping: candidateDocuments, by: \.2)

        var matchesByArtifactID: [PhysicalArtifact.ID: [PossibleSameInvoiceMatch]] = [:]
        for group in documentsBySignature.values where group.count > 1 {
            let documents = group.map { ($0.0, $0.1) }

            for (document, _) in documents {
                let otherMatches = documents
                    .filter { $0.0.id != document.id }
                    .compactMap { makePossibleSameInvoiceMatch(from: $0.0, metadata: $0.1) }

                guard !otherMatches.isEmpty else { continue }
                for artifactID in document.artifactIDs {
                    matchesByArtifactID[artifactID] = otherMatches
                }
            }
        }

        return matchesByArtifactID
    }

    private func sameInvoiceMetadata(for document: Document) -> DocumentMetadata {
        if !document.metadata.isEmpty {
            return document.metadata
        }

        return inferredStructuredDocumentMetadata(for: document) ?? .empty
    }

    private func makePossibleSameInvoiceMatch(
        from document: Document,
        metadata: DocumentMetadata
    ) -> PossibleSameInvoiceMatch? {
        guard let referenceArtifact = document.artifacts.sorted(by: possibleSameInvoiceReferencePriority).first else {
            return nil
        }

        return PossibleSameInvoiceMatch(
            documentID: document.id,
            matchedArtifactID: referenceArtifact.id,
            matchedFileURL: referenceArtifact.fileURL,
            matchedLocation: referenceArtifact.location,
            artifactCount: document.artifacts.count,
            metadata: metadata
        )
    }
}

private func possibleSameInvoiceReferencePriority(lhs: DocumentArtifactReference, rhs: DocumentArtifactReference) -> Bool {
    let lhsLocationPriority = possibleSameInvoiceLocationPriority(lhs.location)
    let rhsLocationPriority = possibleSameInvoiceLocationPriority(rhs.location)

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

private func possibleSameInvoiceLocationPriority(_ location: InvoiceLocation) -> Int {
    switch location {
    case .processed:
        return 0
    case .processing:
        return 1
    case .inbox:
        return 2
    }
}

private struct SameInvoiceSignature: Hashable {
    let vendor: String
    let invoiceDate: Date
    let documentType: DocumentType
    let invoiceNumber: String?

    init?(metadata: DocumentMetadata) {
        guard let vendor = normalizedField(metadata.vendor),
              let invoiceDate = metadata.invoiceDate,
              let documentType = metadata.documentType else {
            return nil
        }

        let invoiceNumber = normalizedField(metadata.invoiceNumber)
        switch documentType {
        case .invoice:
            guard invoiceNumber != nil else { return nil }
        case .receipt:
            break
        }

        self.vendor = vendor
        self.invoiceDate = invoiceDate
        self.documentType = documentType
        self.invoiceNumber = invoiceNumber
    }
}

private func normalizedField(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }

    return trimmed
}

private extension PhysicalArtifact {
    init(reference: DocumentArtifactReference) {
        self.init(
            name: reference.fileURL.lastPathComponent,
            fileURL: reference.fileURL,
            location: reference.location,
            addedAt: reference.addedAt,
            modifiedAt: reference.modifiedAt,
            fileType: reference.fileType,
            status: .unprocessed,
            contentHash: reference.contentHash
        )
    }
}
