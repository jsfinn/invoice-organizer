import Foundation

struct WorkflowActionResult {
    var workflowsByID: [String: StoredInvoiceWorkflow]
    var selectedArtifactIDs: Set<PhysicalArtifact.ID>
}

struct WorkflowRenameResult {
    var artifacts: [PhysicalArtifact]
    var workflowsByID: [String: StoredInvoiceWorkflow]
    var selectedArtifactIDs: Set<PhysicalArtifact.ID>
    var selectedArtifactID: PhysicalArtifact.ID?
    var updatedArtifactID: PhysicalArtifact.ID
}

struct WorkflowActionCoordinator {

    func moveToInProgress(
        documents: [Document],
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        processingRoot: URL,
        duplicatesRoot: URL,
        structuredRecordForContentHash: (String) -> InvoiceStructuredDataRecord?
    ) throws -> WorkflowActionResult {
        guard !documents.isEmpty else {
            return WorkflowActionResult(workflowsByID: workflowsByID, selectedArtifactIDs: [])
        }

        var nextWorkflows = workflowsByID
        var movedIDs: Set<PhysicalArtifact.ID> = []

        for document in documents {
            guard let preferred = document.preferredArtifact,
                  let artifact = artifactsByID[preferred.id] else {
                continue
            }

            for duplicate in document.artifacts where duplicate.id != preferred.id && duplicate.location != .processed {
                if let duplicateArtifact = artifactsByID[duplicate.id] {
                    _ = try InvoiceWorkspaceMover.moveToDuplicates(duplicateArtifact, duplicatesRoot: duplicatesRoot)
                }
            }

            let destinationURL = try InvoiceWorkspaceMover.moveToProcessing(artifact, processingRoot: processingRoot)
            let oldID = artifact.id
            var finalURL = destinationURL
            var workflow = nextWorkflows.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                vendor: document.metadata.vendor,
                invoiceDate: document.metadata.invoiceDate,
                invoiceNumber: document.metadata.invoiceNumber,
                documentType: document.metadata.documentType,
                isInProgress: false
            )
            workflow.isInProgress = false

            if shouldRenameOnMoveToInProgress(
                artifact: artifact,
                workflow: workflow,
                fallbackMetadata: document.metadata,
                structuredRecordForContentHash: structuredRecordForContentHash
            ) {
                let processingArtifact = PhysicalArtifact(
                    name: finalURL.lastPathComponent,
                    fileURL: finalURL,
                    location: .processing,
                    addedAt: artifact.addedAt,
                    modifiedAt: artifact.modifiedAt,
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
            movedIDs.insert(newID)
        }

        return WorkflowActionResult(workflowsByID: nextWorkflows, selectedArtifactIDs: movedIDs)
    }

    func moveToUnprocessed(
        documents: [Document],
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        inboxRoot: URL
    ) throws -> WorkflowActionResult {
        guard !documents.isEmpty else {
            return WorkflowActionResult(workflowsByID: workflowsByID, selectedArtifactIDs: [])
        }

        var nextWorkflows = workflowsByID
        var movedIDs: Set<PhysicalArtifact.ID> = []

        for document in documents {
            guard let ref = document.artifacts.first(where: { $0.location == .processing }),
                  let artifact = artifactsByID[ref.id] else {
                continue
            }

            let destinationURL = try InvoiceWorkspaceMover.moveToInbox(artifact, inboxRoot: inboxRoot)
            let oldID = artifact.id
            let newID = PhysicalArtifact.stableID(for: destinationURL)
            let workflow = nextWorkflows.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                vendor: document.metadata.vendor,
                invoiceDate: document.metadata.invoiceDate,
                invoiceNumber: document.metadata.invoiceNumber,
                documentType: document.metadata.documentType,
                isInProgress: false
            )
            nextWorkflows[newID] = workflow
            movedIDs.insert(newID)
        }

        return WorkflowActionResult(workflowsByID: nextWorkflows, selectedArtifactIDs: movedIDs)
    }

    func reopenToInProgress(
        documents: [Document],
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        processingRoot: URL
    ) throws -> WorkflowActionResult {
        guard !documents.isEmpty else {
            return WorkflowActionResult(workflowsByID: workflowsByID, selectedArtifactIDs: [])
        }

        var nextWorkflows = workflowsByID
        var movedIDs: Set<PhysicalArtifact.ID> = []

        for document in documents {
            guard let ref = document.artifacts.first(where: { $0.location == .processed }),
                  let artifact = artifactsByID[ref.id] else {
                continue
            }

            let destinationURL = try InvoiceWorkspaceMover.moveToProcessing(artifact, processingRoot: processingRoot)
            let oldID = artifact.id
            let newID = PhysicalArtifact.stableID(for: destinationURL)
            var workflow = nextWorkflows.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                vendor: document.metadata.vendor,
                invoiceDate: document.metadata.invoiceDate,
                invoiceNumber: document.metadata.invoiceNumber,
                documentType: document.metadata.documentType,
                isInProgress: false
            )
            workflow.isInProgress = true
            nextWorkflows[newID] = workflow
            movedIDs.insert(newID)
        }

        return WorkflowActionResult(workflowsByID: nextWorkflows, selectedArtifactIDs: movedIDs)
    }

    func moveToProcessed(
        documents: [Document],
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        processedRoot: URL
    ) throws -> WorkflowActionResult {
        guard !documents.isEmpty else {
            return WorkflowActionResult(workflowsByID: workflowsByID, selectedArtifactIDs: [])
        }

        var nextWorkflows = workflowsByID
        var archivedIDs: Set<PhysicalArtifact.ID> = []

        for document in documents {
            guard let ref = document.artifacts.first(where: { $0.location == .processing }),
                  let artifact = artifactsByID[ref.id] else {
                continue
            }

            let metadata = document.metadata
            let vendor = metadata.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let invoiceDate = metadata.invoiceDate ?? artifact.addedAt
            let destinationURL = try InvoiceArchiver.archive(
                artifact,
                processedRoot: processedRoot,
                vendor: vendor,
                invoiceDate: invoiceDate,
                invoiceNumber: metadata.invoiceNumber
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
            archivedIDs.insert(archivedID)
        }

        return WorkflowActionResult(workflowsByID: nextWorkflows, selectedArtifactIDs: archivedIDs)
    }

    func moveToArchive(
        documents: [Document],
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        archiveRoot: URL
    ) throws -> WorkflowActionResult {
        guard !documents.isEmpty else {
            return WorkflowActionResult(workflowsByID: workflowsByID, selectedArtifactIDs: [])
        }

        var nextWorkflows = workflowsByID

        for document in documents {
            for ref in document.artifacts {
                if let artifact = artifactsByID[ref.id] {
                    _ = try InvoiceWorkspaceMover.moveToArchive(artifact, archiveRoot: archiveRoot)
                    nextWorkflows.removeValue(forKey: artifact.id)
                }
            }
        }

        return WorkflowActionResult(workflowsByID: nextWorkflows, selectedArtifactIDs: [])
    }

    func applyWorkflow(
        _ workflow: StoredInvoiceWorkflow,
        to artifactID: PhysicalArtifact.ID,
        artifacts: [PhysicalArtifact],
        workflowsByID: [String: StoredInvoiceWorkflow],
        selectedArtifactIDs: Set<PhysicalArtifact.ID>,
        selectedArtifactID: PhysicalArtifact.ID?
    ) throws -> WorkflowRenameResult? {
        guard let index = artifacts.firstIndex(where: { $0.id == artifactID }) else {
            return nil
        }

        var nextArtifacts = artifacts
        var nextWorkflows = workflowsByID
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
                modifiedAt: artifact.modifiedAt,
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
        nextArtifacts[index] = targetArtifact

        let remappedSelection = Set(selectedArtifactIDs.map { $0 == artifactID ? nextID : $0 })
        let remappedPrimary = selectedArtifactID == artifactID ? nextID : selectedArtifactID

        return WorkflowRenameResult(
            artifacts: nextArtifacts,
            workflowsByID: nextWorkflows,
            selectedArtifactIDs: remappedSelection,
            selectedArtifactID: remappedPrimary,
            updatedArtifactID: nextID
        )
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

    private func normalizedInvoiceNumber(from invoiceNumber: String) -> String? {
        let trimmed = invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
