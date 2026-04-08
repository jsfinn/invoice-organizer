import Foundation

struct WorkflowActionResult {
    var workflowsByID: [String: StoredInvoiceWorkflow]
    var ignoredArtifactIDs: Set<PhysicalArtifact.ID>
    var selectedArtifactIDs: Set<PhysicalArtifact.ID>
}

struct WorkflowRenameResult {
    var artifacts: [PhysicalArtifact]
    var workflowsByID: [String: StoredInvoiceWorkflow]
    var ignoredArtifactIDs: Set<PhysicalArtifact.ID>
    var selectedArtifactIDs: Set<PhysicalArtifact.ID>
    var selectedArtifactID: PhysicalArtifact.ID?
    var updatedArtifactID: PhysicalArtifact.ID
}

struct WorkflowActionCoordinator {
    func orderedProcessingIDs(
        requestedIDs: Set<PhysicalArtifact.ID>,
        visibleArtifacts: [PhysicalArtifact],
        allArtifacts: [PhysicalArtifact]
    ) -> [PhysicalArtifact.ID] {
        let visibleOrderedIDs = visibleArtifacts
            .map(\.id)
            .filter { requestedIDs.contains($0) }
        let visibleOrderedSet = Set(visibleOrderedIDs)
        let remainingIDs = allArtifacts
            .map(\.id)
            .filter { requestedIDs.contains($0) && !visibleOrderedSet.contains($0) }
        return visibleOrderedIDs + remainingIDs
    }

    func moveToInProgress(
        orderedIDs: [PhysicalArtifact.ID],
        artifacts: [PhysicalArtifact],
        snapshot: LibrarySnapshot,
        workflowsByID: [String: StoredInvoiceWorkflow],
        ignoredArtifactIDs: Set<PhysicalArtifact.ID>,
        processingRoot: URL,
        duplicatesRoot: URL,
        structuredRecordForContentHash: (String) -> InvoiceStructuredDataRecord?
    ) throws -> WorkflowActionResult {
        let artifactByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        let eligibleArtifacts = orderedIDs.compactMap { artifactByID[$0] }.filter(\.canMoveToInProgress)
        guard !eligibleArtifacts.isEmpty else {
            return WorkflowActionResult(
                workflowsByID: workflowsByID,
                ignoredArtifactIDs: ignoredArtifactIDs,
                selectedArtifactIDs: []
            )
        }

        var nextWorkflows = workflowsByID
        var nextIgnoredIDs = ignoredArtifactIDs
        var movedIDs: Set<PhysicalArtifact.ID> = []
        let movePlan = processingMovePlan(for: eligibleArtifacts.map(\.id), snapshot: snapshot)

        for artifact in artifacts where movePlan.duplicateIDs.contains(artifact.id) {
            _ = try InvoiceWorkspaceMover.moveToDuplicates(artifact, duplicatesRoot: duplicatesRoot)
        }

        for artifactID in movePlan.processingIDs {
            guard let artifact = artifactByID[artifactID] else { continue }
            let destinationURL = try InvoiceWorkspaceMover.moveToProcessing(artifact, processingRoot: processingRoot)
            let metadata = snapshot.metadata(for: artifactID)
            let oldID = artifact.id
            var finalURL = destinationURL
            var workflow = nextWorkflows.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: false
            )
            workflow.isInProgress = false

            if shouldRenameOnMoveToInProgress(
                artifact: artifact,
                workflow: workflow,
                fallbackMetadata: metadata,
                structuredRecordForContentHash: structuredRecordForContentHash
            ) {
                let processingArtifact = PhysicalArtifact(
                    name: finalURL.lastPathComponent,
                    fileURL: finalURL,
                    location: .processing,
                    addedAt: artifact.addedAt,
                    fileType: artifact.fileType,
                    status: .inProgress,
                    contentHash: artifact.contentHash,
                    duplicateOfPath: artifact.duplicateOfPath,
                    duplicateReason: artifact.duplicateReason
                )
                finalURL = try InvoiceWorkspaceMover.renameInProcessing(
                    processingArtifact,
                    vendor: workflow.vendor,
                    invoiceDate: workflow.invoiceDate,
                    invoiceNumber: workflow.invoiceNumber
                )
            }

            let newID = PhysicalArtifact.stableID(for: finalURL)
            nextWorkflows[newID] = workflow
            remapIgnoredID(from: oldID, to: newID, ignoredArtifactIDs: &nextIgnoredIDs)
            movedIDs.insert(newID)
        }

        return WorkflowActionResult(
            workflowsByID: nextWorkflows,
            ignoredArtifactIDs: nextIgnoredIDs,
            selectedArtifactIDs: movedIDs
        )
    }

    func moveToUnprocessed(
        ids: Set<PhysicalArtifact.ID>,
        artifacts: [PhysicalArtifact],
        snapshot: LibrarySnapshot,
        workflowsByID: [String: StoredInvoiceWorkflow],
        ignoredArtifactIDs: Set<PhysicalArtifact.ID>,
        inboxRoot: URL
    ) throws -> WorkflowActionResult {
        let eligibleIDs = Set(artifacts.filter { ids.contains($0.id) && $0.location == .processing }.map(\.id))
        guard !eligibleIDs.isEmpty else {
            return WorkflowActionResult(
                workflowsByID: workflowsByID,
                ignoredArtifactIDs: ignoredArtifactIDs,
                selectedArtifactIDs: []
            )
        }

        var nextWorkflows = workflowsByID
        var nextIgnoredIDs = ignoredArtifactIDs
        var movedIDs: Set<PhysicalArtifact.ID> = []

        for artifact in artifacts where eligibleIDs.contains(artifact.id) {
            let destinationURL = try InvoiceWorkspaceMover.moveToInbox(artifact, inboxRoot: inboxRoot)
            let oldID = artifact.id
            let newID = PhysicalArtifact.stableID(for: destinationURL)
            let metadata = snapshot.metadata(for: oldID)
            let workflow = nextWorkflows.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: false
            )
            nextWorkflows[newID] = workflow
            remapIgnoredID(from: oldID, to: newID, ignoredArtifactIDs: &nextIgnoredIDs)
            movedIDs.insert(newID)
        }

        return WorkflowActionResult(
            workflowsByID: nextWorkflows,
            ignoredArtifactIDs: nextIgnoredIDs,
            selectedArtifactIDs: movedIDs
        )
    }

    func moveToProcessed(
        ids: Set<PhysicalArtifact.ID>,
        artifacts: [PhysicalArtifact],
        snapshot: LibrarySnapshot,
        workflowsByID: [String: StoredInvoiceWorkflow],
        ignoredArtifactIDs: Set<PhysicalArtifact.ID>,
        processedRoot: URL
    ) throws -> WorkflowActionResult {
        let eligibleArtifacts = artifacts.filter { ids.contains($0.id) && $0.canMarkDone }
        guard !eligibleArtifacts.isEmpty else {
            return WorkflowActionResult(
                workflowsByID: workflowsByID,
                ignoredArtifactIDs: ignoredArtifactIDs,
                selectedArtifactIDs: []
            )
        }

        var nextWorkflows = workflowsByID
        var nextIgnoredIDs = ignoredArtifactIDs
        var archivedIDs: Set<PhysicalArtifact.ID> = []
        let processedAt = Date()

        for artifact in eligibleArtifacts {
            let metadata = snapshot.metadata(for: artifact.id)
            let vendor = metadata.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let invoiceDate = metadata.invoiceDate ?? artifact.addedAt
            let destinationURL = try InvoiceArchiver.archive(
                artifact,
                processedRoot: processedRoot,
                vendor: vendor,
                invoiceDate: invoiceDate,
                processedAt: processedAt
            )

            let archivedID = PhysicalArtifact.stableID(for: destinationURL)
            var workflow = nextWorkflows.removeValue(forKey: artifact.id) ?? StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: false
            )
            workflow.vendor = vendor
            workflow.invoiceDate = invoiceDate
            workflow.invoiceNumber = normalizedInvoiceNumber(from: metadata.invoiceNumber ?? "")
            workflow.documentType = metadata.documentType
            workflow.isInProgress = false
            nextWorkflows[archivedID] = workflow
            remapIgnoredID(from: artifact.id, to: archivedID, ignoredArtifactIDs: &nextIgnoredIDs)
            archivedIDs.insert(archivedID)
        }

        return WorkflowActionResult(
            workflowsByID: nextWorkflows,
            ignoredArtifactIDs: nextIgnoredIDs,
            selectedArtifactIDs: archivedIDs
        )
    }

    func applyWorkflow(
        _ workflow: StoredInvoiceWorkflow,
        to artifactID: PhysicalArtifact.ID,
        artifacts: [PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        ignoredArtifactIDs: Set<PhysicalArtifact.ID>,
        selectedArtifactIDs: Set<PhysicalArtifact.ID>,
        selectedArtifactID: PhysicalArtifact.ID?
    ) throws -> WorkflowRenameResult? {
        guard let index = artifacts.firstIndex(where: { $0.id == artifactID }) else {
            return nil
        }

        var nextArtifacts = artifacts
        var nextWorkflows = workflowsByID
        var nextIgnoredIDs = ignoredArtifactIDs
        let artifact = artifacts[index]
        var targetArtifact = artifact
        var nextID = artifactID

        if artifact.location == .processing {
            let renamedURL = try InvoiceWorkspaceMover.renameInProcessing(
                artifact,
                vendor: workflow.vendor,
                invoiceDate: workflow.invoiceDate,
                invoiceNumber: workflow.invoiceNumber
            )
            targetArtifact = PhysicalArtifact(
                name: renamedURL.lastPathComponent,
                fileURL: renamedURL,
                location: artifact.location,
                processedAt: artifact.processedAt,
                addedAt: artifact.addedAt,
                fileType: artifact.fileType,
                status: artifact.status,
                contentHash: artifact.contentHash,
                duplicateOfPath: artifact.duplicateOfPath,
                duplicateReason: artifact.duplicateReason
            )
            nextID = targetArtifact.id
        }

        nextWorkflows.removeValue(forKey: artifactID)
        nextWorkflows[nextID] = workflow
        remapIgnoredID(from: artifactID, to: nextID, ignoredArtifactIDs: &nextIgnoredIDs)
        nextArtifacts[index] = targetArtifact

        let remappedSelection = Set(selectedArtifactIDs.map { $0 == artifactID ? nextID : $0 })
        let remappedPrimary = selectedArtifactID == artifactID ? nextID : selectedArtifactID

        return WorkflowRenameResult(
            artifacts: nextArtifacts,
            workflowsByID: nextWorkflows,
            ignoredArtifactIDs: nextIgnoredIDs,
            selectedArtifactIDs: remappedSelection,
            selectedArtifactID: remappedPrimary,
            updatedArtifactID: nextID
        )
    }

    private func processingMovePlan(
        for orderedIDs: [PhysicalArtifact.ID],
        snapshot: LibrarySnapshot
    ) -> (processingIDs: [PhysicalArtifact.ID], duplicateIDs: Set<PhysicalArtifact.ID>) {
        var processingIDs: [PhysicalArtifact.ID] = []
        var duplicateIDs: Set<PhysicalArtifact.ID> = []
        var handledDocumentIDs: Set<Document.ID> = []

        for artifactID in orderedIDs {
            guard let document = snapshot.document(for: artifactID), document.isDuplicate else {
                processingIDs.append(artifactID)
                continue
            }

            if handledDocumentIDs.insert(document.id).inserted {
                processingIDs.append(artifactID)
                duplicateIDs.formUnion(
                    document.artifacts.compactMap { artifact in
                        guard artifact.location != .processed,
                              artifact.id != artifactID else {
                            return nil
                        }

                        return artifact.id
                    }
                )
            } else {
                duplicateIDs.insert(artifactID)
            }
        }

        return (processingIDs, duplicateIDs)
    }

    private func shouldRenameOnMoveToInProgress(
        artifact: PhysicalArtifact,
        workflow: StoredInvoiceWorkflow,
        fallbackMetadata: DocumentMetadata,
        structuredRecordForContentHash: (String) -> InvoiceStructuredDataRecord?
    ) -> Bool {
        guard let contentHash = artifact.contentHash,
              let structuredRecord = structuredRecordForContentHash(contentHash),
              structuredRecord.isHighConfidence else {
            return false
        }

        let vendor = (workflow.vendor ?? fallbackMetadata.vendor)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoiceDate = workflow.invoiceDate ?? fallbackMetadata.invoiceDate
        return !(vendor?.isEmpty ?? true) && invoiceDate != nil
    }

    private func remapIgnoredID(
        from previousID: PhysicalArtifact.ID,
        to updatedID: PhysicalArtifact.ID,
        ignoredArtifactIDs: inout Set<PhysicalArtifact.ID>
    ) {
        guard previousID != updatedID, ignoredArtifactIDs.remove(previousID) != nil else {
            return
        }

        ignoredArtifactIDs.insert(updatedID)
    }

    private func normalizedInvoiceNumber(from invoiceNumber: String) -> String? {
        let trimmed = invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
