import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var invoices: [PhysicalArtifact]
    @Published var queueScreenContext: QueueScreenContext
    @Published var folderSettings: FolderSettings
    @Published var heicConversionSettings: HEICConversionSettings
    @Published var llmSettings: LLMSettings
    @Published var settingsErrorMessage: String?
    @Published private(set) var llmPreflightStatus: LLMPreflightStatus
    @Published private(set) var documents: [Document] = []
    @Published private(set) var extractedTextHashes: Set<String> = []
    @Published private(set) var structuredDataHashes: Set<String> = []
    @Published private(set) var textPendingHashes: Set<String> = []
    @Published private(set) var textFailedHashes: Set<String> = []
    @Published private(set) var structuredPendingHashes: Set<String> = []
    @Published private(set) var structuredFailedHashes: Set<String> = []
    @Published private(set) var textQueueDepth: Int = 0
    @Published private(set) var structuredQueueDepth: Int = 0
    let heicConversionQueue = HEICConversionQueueModel()

    private let accessCoordinator = ArtifactAccessCoordinator()
    private let openInPreviewHandler: ([URL]) -> Void
    private let moveToTrashHandler: (URL) throws -> Void
    private let computationCache: ArtifactComputationCache
    private let snapshotBuilder: LibrarySnapshotBuilder
    private let textStore: any InvoiceTextStoring
    private let textExtractionHandler: TextExtractionHandler
    private let textExtractionQueue: ContentHashQueue<TextExtractionHandler>
    private let structuredDataStore: any InvoiceStructuredDataStoring
    private let structuredExtractionClient: any InvoiceStructuredExtractionClient
    private let structuredExtractionHandler: StructuredExtractionHandler
    private let structuredExtractionQueue: ContentHashQueue<StructuredExtractionHandler>
    private let workflowActionCoordinator = WorkflowActionCoordinator()
    private let filenameReconciler = FilenameReconciler()
    private var workflowPersister: WorkflowPersister!
    private var filenameReconcilerTask: Task<Void, Never>?
    private lazy var fileSystemReconciler = FileSystemReconciler(
        folderSettings: folderSettings,
        workflowProvider: { [weak self] in
            self?.workflowByID ?? [:]
        },
        onSnapshot: { [weak self] result in
            await self?.handleFileSystemReconciliation(result)
        }
    )
    private var queueHandlerSetupTask: Task<Void, Never>?
    private var librarySnapshot: LibrarySnapshot = .empty
    private var workflowByID: [String: StoredInvoiceWorkflow]
    private var separatedContentHashPairs: Set<ContentHashPair> = DuplicateOverrideStore.load()
    private var documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata] = [:]
    private var rescannedDocumentContextsByID: [Document.ID: DocumentRescanContext] = [:]
    private var rescannedDocumentIDsByHash: [String: Set<Document.ID>] = [:]
    private var pendingPreferredSelectionID: PhysicalArtifact.ID?
    private var isSynchronizingSelection = false
    private var didRunStartupHEICCheck = false

    init(
        folderSettings: FolderSettings? = nil,
        workflowByID: [String: StoredInvoiceWorkflow]? = nil,
        textStore: any InvoiceTextStoring = InvoiceTextStore.shared,
        textExtractor: any DocumentTextExtracting = DocumentTextExtractor(),
        structuredDataStore: any InvoiceStructuredDataStoring = InvoiceStructuredDataStore.shared,
        structuredExtractionClient: any InvoiceStructuredExtractionClient = RoutedStructuredExtractionClient(),
        llmSettings: LLMSettings? = nil,
        autoRefresh: Bool = true,
        openInPreview: (([URL]) -> Void)? = nil,
        moveToTrash: ((URL) throws -> Void)? = nil
    ) {
        let resolvedFolderSettings = folderSettings ?? Self.loadFolderSettings()
        let resolvedHEICConversionSettings = Self.loadHEICConversionSettings()
        let resolvedLLMSettings = llmSettings ?? Self.loadLLMSettings()

        self.queueScreenContext = QueueScreenContext()
        self.folderSettings = resolvedFolderSettings
        self.heicConversionSettings = resolvedHEICConversionSettings
        self.llmSettings = resolvedLLMSettings
        self.workflowByID = Self.migrateWorkflowKeysIfNeeded(workflowByID ?? InvoiceWorkflowStore.load())
        self.openInPreviewHandler = openInPreview ?? { urls in
            AppModel.systemOpenInPreview(urls)
        }
        self.moveToTrashHandler = moveToTrash ?? { url in
            _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        self.textStore = textStore
        self.structuredDataStore = structuredDataStore
        self.computationCache = ArtifactComputationCache(
            textStore: textStore,
            structuredDataStore: structuredDataStore
        )
        self.snapshotBuilder = LibrarySnapshotBuilder(
            structuredRecordForContentHash: { [computationCache = self.computationCache] contentHash in
                computationCache.structuredRecord(forContentHash: contentHash)
            }
        )
        self.structuredExtractionClient = structuredExtractionClient
        self.llmPreflightStatus = Self.initialLLMPreflightStatus(for: resolvedLLMSettings)
        let textHandler = TextExtractionHandler(store: textStore, extractor: textExtractor)
        self.textExtractionHandler = textHandler
        self.textExtractionQueue = ContentHashQueue(handler: textHandler)

        let structuredHandler = StructuredExtractionHandler(
            textStore: textStore,
            structuredDataStore: structuredDataStore,
            client: structuredExtractionClient
        )
        self.structuredExtractionHandler = structuredHandler
        self.structuredExtractionQueue = ContentHashQueue(handler: structuredHandler)

        self.invoices = []
        self.queueHandlerSetupTask = Task { [textExtractionQueue = self.textExtractionQueue, structuredExtractionQueue = self.structuredExtractionQueue] in
            textHandler.onRequestStarted = { contentHash in
                self.textPendingHashes.insert(contentHash)
                self.textFailedHashes.remove(contentHash)
            }
            textHandler.onRecordSaved = { contentHash in
                await self.handleExtractedTextSaved(contentHash)
            }
            textHandler.onRequestFailed = { contentHash in
                self.textPendingHashes.remove(contentHash)
                self.textFailedHashes.insert(contentHash)
                self.handleRescannedDocumentContentHashCompleted(contentHash)
                self.rebuildLibrarySnapshot()
            }
            structuredHandler.onRequestStarted = { contentHash in
                self.structuredPendingHashes.insert(contentHash)
                self.structuredFailedHashes.remove(contentHash)
            }
            structuredHandler.onRecordSaved = { contentHash, record in
                self.handleStructuredDataSaved(contentHash: contentHash, record: record)
            }
            structuredHandler.onRequestFailed = { contentHash, status in
                self.structuredPendingHashes.remove(contentHash)
                self.structuredFailedHashes.insert(contentHash)
                self.handleRescannedDocumentContentHashCompleted(contentHash)
                self.llmPreflightStatus = status
            }
            await textExtractionQueue.setOnQueueDepthChanged { depth in
                self.textQueueDepth = depth
            }
            await structuredExtractionQueue.setOnQueueDepthChanged { depth in
                self.structuredQueueDepth = depth
            }
        }
        self.workflowPersister = WorkflowPersister { [weak self] in
            guard let self else { return }
            InvoiceWorkflowStore.save(self.workflowByID)
        }
        filenameReconcilerTask = Task { [weak self, filenameReconciler] in
            for await result in filenameReconciler.results {
                self?.applyFilenameRenameResult(result)
            }
        }
        fileSystemReconciler.updateConfiguration(folderSettings: resolvedFolderSettings, autoRefresh: autoRefresh)
    }

    var selectedArtifactIDs: Set<PhysicalArtifact.ID> {
        get { activeQueueTabContext.selectedArtifactIDs }
        set {
            guard newValue != selectedArtifactIDs else { return }
            setSelectedArtifactIDs(newValue)
        }
    }

    var selectedArtifactID: PhysicalArtifact.ID? {
        get { activeQueueTabContext.selectedArtifactID }
        set {
            guard newValue != selectedArtifactID else { return }
            setSelectedArtifactID(newValue)
        }
    }

    var selectedQueueTab: InvoiceQueueTab {
        get { queueScreenContext.selectedTab }
        set {
            guard newValue != selectedQueueTab else { return }
            setSelectedQueueTab(newValue)
        }
    }

    var searchText: String {
        get { activeQueueTabContext.searchText }
        set {
            guard newValue != searchText else { return }
            setSearchText(newValue)
        }
    }

    var selectedArtifact: PhysicalArtifact? {
        guard let selectedArtifactID else { return nil }
        return invoices.first(where: { $0.id == selectedArtifactID })
    }

    func document(for artifactID: PhysicalArtifact.ID) -> Document? {
        librarySnapshot.document(for: artifactID)
    }

    func documentMetadata(for artifactID: PhysicalArtifact.ID) -> DocumentMetadata {
        librarySnapshot.metadata(for: artifactID)
    }

    func possibleSameInvoiceMatches(for artifactID: PhysicalArtifact.ID) -> [PossibleSameInvoiceMatch] {
        librarySnapshot.possibleSameInvoiceMatchesByArtifactID[artifactID] ?? []
    }

    var documentMetadataByArtifactID: [PhysicalArtifact.ID: DocumentMetadata] {
        librarySnapshot.documentMetadataByArtifactID
    }

    func dedupSummary(for artifactID: PhysicalArtifact.ID) -> DedupSummary {
        guard let artifact = invoices.first(where: { $0.id == artifactID }) else {
            return DedupSummary(groupingStatus: .singleton, identityDescription: nil, extractionState: .notStarted, comparisons: [])
        }

        let contentHash = artifact.contentHash
        let hasText = contentHash.map { extractedTextArtifactIDs.contains(artifactID) || computationCache.duplicateTermFrequencies(forContentHash: $0) != nil } ?? false
        let record = contentHash.flatMap { computationCache.structuredRecord(forContentHash: $0) }
        let identity = record.flatMap { DocumentIdentity(record: $0) }

        let extractionState: DedupSummary.ExtractionState
        if identity != nil { extractionState = .complete }
        else if hasText { extractionState = .textOnly }
        else { extractionState = .notStarted }

        let identityDescription: String?
        if let identity {
            let dateFmt = identity.invoiceDate.formatted(date: .abbreviated, time: .omitted)
            if let num = identity.invoiceNumber {
                identityDescription = "\(identity.vendor) / \(num) / \(dateFmt) (\(identity.documentType.rawValue.lowercased()))"
            } else {
                identityDescription = "\(identity.vendor) / \(dateFmt) (\(identity.documentType.rawValue.lowercased()))"
            }
        } else {
            identityDescription = nil
        }

        let document = librarySnapshot.document(for: artifactID)
        let groupingStatus: DedupSummary.GroupingStatus
        if let document, document.isDuplicate, let ref = document.referenceArtifact(for: artifactID) {
            let refName = ref.fileURL.lastPathComponent
            switch document.matchKind(forArtifactID: artifactID) {
            case .identicalFile:
                groupingStatus = .identicalCopy(referenceFile: refName)
            case .sameDocument, nil:
                if identity != nil {
                    groupingStatus = .duplicateGrouped(referenceFile: refName, reason: "Matched by structured identity")
                } else {
                    groupingStatus = .duplicateGrouped(referenceFile: refName, reason: "Matched by text similarity")
                }
            }
        } else {
            groupingStatus = .singleton
        }

        let contentHashByArtifactID = Dictionary(
            librarySnapshot.artifacts.compactMap { a -> (PhysicalArtifact.ID, String)? in
                guard let h = a.contentHash else { return nil }
                return (a.id, h)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        let candidateTerms = contentHash.flatMap { computationCache.duplicateTermFrequencies(forContentHash: $0) }
        let allFreqs = Array(librarySnapshot.duplicateTermFrequenciesByArtifactID.values)
        let (documentFrequencies, documentCount) = DuplicateDetector.computeDocumentFrequencies(from: allFreqs)

        let comparisons: [DedupComparison] = librarySnapshot.documents
            .filter { !$0.contains(artifactID: artifactID) }
            .compactMap { otherDoc -> DedupComparison? in
                guard let bestArtifact = otherDoc.artifacts.first else { return nil }
                let otherHash = contentHashByArtifactID[bestArtifact.id]
                let otherRecord = otherHash.flatMap { computationCache.structuredRecord(forContentHash: $0) }
                let otherIdentity = otherRecord.flatMap { DocumentIdentity(record: $0) }

                var textScore: Double? = nil
                if let candidateTerms, let otherTerms = librarySnapshot.duplicateTermFrequenciesByArtifactID[bestArtifact.id] {
                    textScore = DuplicateDetector.cosineSimilarity(
                        lhs: candidateTerms, rhs: otherTerms,
                        documentFrequencies: documentFrequencies, documentCount: documentCount
                    )
                }

                let identityRelation: DedupComparison.IdentityRelation?
                if let identity, let otherIdentity {
                    if identity.isPositiveMatch(otherIdentity) {
                        identityRelation = .positiveMatch
                    } else if let reason = identity.conflictReason(with: otherIdentity) {
                        identityRelation = .conflict(reason: reason)
                    } else {
                        identityRelation = nil
                    }
                } else if identity != nil || otherIdentity != nil {
                    identityRelation = .noIdentity
                } else {
                    identityRelation = nil
                }

                let decision: DedupComparison.Decision
                if let identityRelation {
                    switch identityRelation {
                    case .positiveMatch:
                        decision = .grouped
                    case .conflict(let reason):
                        decision = .vetoed(reason: reason)
                    case .noIdentity:
                        if let textScore, textScore >= duplicateSimilarityThreshold {
                            decision = .pending(reason: "Grouped by text, extraction pending on one side")
                        } else if let textScore, textScore > 0 {
                            decision = .belowThreshold
                        } else {
                            decision = .pending(reason: "Waiting for text extraction")
                        }
                    }
                } else if contentHash != nil, otherHash != nil, contentHash == otherHash {
                    decision = .grouped
                } else if let textScore, textScore >= duplicateSimilarityThreshold {
                    decision = .grouped
                } else {
                    decision = .belowThreshold
                }

                guard textScore != nil || identityRelation != nil || (contentHash != nil && contentHash == otherHash) else {
                    return nil
                }

                return DedupComparison(
                    documentID: otherDoc.id,
                    fileName: bestArtifact.fileURL.lastPathComponent,
                    location: bestArtifact.location,
                    artifactCount: otherDoc.artifacts.count,
                    decision: decision,
                    textScore: textScore,
                    identityRelation: identityRelation
                )
            }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.decision.sortPriority
                let rhsPriority = rhs.decision.sortPriority
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return (lhs.textScore ?? 0) > (rhs.textScore ?? 0)
            }
            .prefix(8)
            .map { $0 }

        return DedupSummary(
            groupingStatus: groupingStatus,
            identityDescription: identityDescription,
            extractionState: extractionState,
            comparisons: comparisons
        )
    }

    func duplicateSimilarities(for artifactID: PhysicalArtifact.ID, limit: Int = 5) -> [DuplicateSimilarity] {
        guard let artifact = invoices.first(where: { $0.id == artifactID }),
              let contentHash = artifact.contentHash,
              let artifactTerms = computationCache.duplicateTermFrequencies(forContentHash: contentHash) else {
            return []
        }

        let candidateRecord = computationCache.structuredRecord(forContentHash: contentHash)
        let contentHashByArtifactID = Dictionary(
            librarySnapshot.artifacts.compactMap { artifact -> (PhysicalArtifact.ID, String)? in
                guard let hash = artifact.contentHash else { return nil }
                return (artifact.id, hash)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        let allFreqs = Array(librarySnapshot.duplicateTermFrequenciesByArtifactID.values)
        let (documentFrequencies, documentCount) = DuplicateDetector.computeDocumentFrequencies(from: allFreqs)

        return librarySnapshot.documents
            .filter { !$0.contains(artifactID: artifactID) }
            .compactMap { document -> DuplicateSimilarity? in
                guard var similarity = document.bestSimilarity(
                    to: artifactTerms,
                    termFrequenciesByArtifactID: librarySnapshot.duplicateTermFrequenciesByArtifactID,
                    documentFrequencies: documentFrequencies,
                    documentCount: documentCount,
                    threshold: duplicateSimilarityThreshold
                ) else {
                    return nil
                }

                let matchedRecord = contentHashByArtifactID[similarity.matchedArtifactID]
                    .flatMap { computationCache.structuredRecord(forContentHash: $0) }
                similarity.vetoReason = DuplicateDetector.structuredVetoReason(
                    between: candidateRecord,
                    and: matchedRecord
                )
                similarity.pendingReason = DuplicateDetector.structuredPendingReason(
                    lhsRecord: candidateRecord,
                    rhsRecord: matchedRecord
                )
                if let matchedHash = contentHashByArtifactID[similarity.matchedArtifactID],
                   matchedHash == contentHash {
                    similarity.matchKind = .identicalFile
                } else {
                    similarity.matchKind = .sameDocument
                }
                return similarity
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }

                return lhs.documentID < rhs.documentID
            }
            .prefix(limit)
            .map { $0 }
    }

    var visibleArtifacts: [PhysicalArtifact] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return invoices
            .filter { invoice in
                switch selectedQueueTab {
                case .unprocessed:
                    return invoice.location == .inbox
                case .inProgress:
                    return invoice.location == .processing
                case .processed:
                    return invoice.location == .processed
                }
            }
            .filter { invoice in
                guard !trimmedSearchText.isEmpty else { return true }

                if invoice.name.localizedCaseInsensitiveContains(trimmedSearchText) {
                    return true
                }

                if let vendor = documentMetadata(for: invoice.id).vendor,
                   vendor.localizedCaseInsensitiveContains(trimmedSearchText) {
                    return true
                }

                return false
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var unprocessedCount: Int {
        invoices.filter { $0.location == .inbox }.count
    }

    var inProgressCount: Int {
        invoices.filter { $0.location == .processing }.count
    }

    var processedCount: Int {
        invoices.filter { $0.location == .processed }.count
    }

    var activeBrowserContext: InvoiceBrowserContext {
        activeQueueTabContext.browserContext
    }

    var duplicateBadgeTitlesByArtifactID: [PhysicalArtifact.ID: String] {
        return Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let title = librarySnapshot.document(for: invoice.id)?.badgeTitle(forArtifactID: invoice.id) else {
                    return nil
                }

                return (invoice.id, title)
            }
        )
    }

    var possibleSameInvoiceBadgeTitlesByArtifactID: [PhysicalArtifact.ID: String] {
        Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard !possibleSameInvoiceMatches(for: invoice.id).isEmpty else { return nil }
                return (invoice.id, "Possible Same Invoice")
            }
        )
    }

    var knownVendors: [String] {
        Array(
            Set(
                documents.compactMap { document in
                    let trimmed = document.metadata.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
            )
        )
        .sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    var hasRequiredFolders: Bool {
        folderSettings.inboxURL != nil &&
        folderSettings.processingURL != nil &&
        folderSettings.processedURL != nil &&
        folderSettings.duplicatesURL != nil
    }

    var inboxFolderDisplayPath: String {
        folderSettings.inboxURL?.path ?? "Not selected"
    }

    var processedFolderDisplayPath: String {
        folderSettings.processedURL?.path ?? "Not selected"
    }

    var processingFolderDisplayPath: String {
        folderSettings.processingURL?.path ?? "Not selected"
    }

    var archiveFolderDisplayPath: String {
        folderSettings.duplicatesURL?.path ?? "Not selected"
    }

    func sourcePathDisplay(for invoice: PhysicalArtifact) -> String {
        accessCoordinator.sourcePathDisplay(for: invoice.handle)
    }

    func processedFolderPreviewPath(for invoice: PhysicalArtifact) -> String? {
        accessCoordinator.processedFolderPreviewPath(
            for: invoice,
            metadata: documentMetadata(for: invoice.id),
            processedRoot: folderSettings.processedURL
        )
    }

    func dragExportURL(for invoice: PhysicalArtifact) throws -> URL {
        try accessCoordinator.dragExportURL(for: invoice.handle)
    }

    func openInPreview(ids: [PhysicalArtifact.ID]) {
        var seenURLs: Set<URL> = []
        let urls = ids.reduce(into: [URL]()) { urls, artifactID in
            guard let handle = invoices.first(where: { $0.id == artifactID })?.handle,
                  accessCoordinator.fileExists(for: handle),
                  seenURLs.insert(handle.fileURL).inserted else {
                return
            }

            urls.append(handle.fileURL)
        }

        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        openInPreviewHandler(urls)
    }

    func showInFinder(ids: [PhysicalArtifact.ID]) {
        var seenURLs: Set<URL> = []
        let urls = ids.reduce(into: [URL]()) { urls, artifactID in
            guard let handle = invoices.first(where: { $0.id == artifactID })?.handle,
                  accessCoordinator.fileExists(for: handle),
                  seenURLs.insert(handle.fileURL).inserted else {
                return
            }

            urls.append(handle.fileURL)
        }

        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func fileIcon(for invoice: PhysicalArtifact) -> NSImage {
        accessCoordinator.fileIcon(for: invoice.handle)
    }

    var isWatchingFolders: Bool {
        fileSystemReconciler.isWatchingFolders
    }

    var llmStatusMessage: String {
        llmPreflightStatus.message
    }

    var extractedTextArtifactIDs: Set<PhysicalArtifact.ID> {
        Set(
            invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      computationCache.extractedTextHashes.contains(contentHash) else {
                    return nil
                }

                return invoice.id
            }
        )
    }

    var duplicateSimilarityThreshold: Double {
        DuplicateDetector.textSimilarityThreshold
    }

    private func syncComputationHashes() {
        extractedTextHashes = computationCache.extractedTextHashes
        structuredDataHashes = computationCache.structuredDataHashes
    }

    nonisolated private static func systemOpenInPreview(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let previewAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open(urls, withApplicationAt: previewAppURL, configuration: configuration) { _, error in
                if error != nil {
                    NSSound.beep()
                }
            }
            return
        }

        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    var ocrStatesByArtifactID: [PhysicalArtifact.ID: InvoiceOCRState] {
        Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      invoice.location == .inbox || invoice.location == .processing else {
                    return nil
                }

                if computationCache.extractedTextHashes.contains(contentHash) {
                    return (invoice.id, .success)
                }

                if textFailedHashes.contains(contentHash) {
                    return (invoice.id, .failed)
                }

                return (invoice.id, .waiting)
            }
        )
    }

    var readStatesByArtifactID: [PhysicalArtifact.ID: InvoiceReadState] {
        Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      invoice.location == .inbox || invoice.location == .processing else {
                    return nil
                }

                if let record = computationCache.structuredRecord(forContentHash: contentHash) {
                    return (invoice.id, record.isHighConfidence ? .success : .review)
                }

                if structuredFailedHashes.contains(contentHash) || textFailedHashes.contains(contentHash) {
                    return (invoice.id, .failed)
                }

                return (invoice.id, .waiting)
            }
        )
    }

    func setSelectedQueueTab(_ tab: InvoiceQueueTab) {
        guard tab != selectedQueueTab else { return }
        updateQueueScreenContext { $0.selectedTab = tab }
        syncSelectionForVisibleInvoices()
    }

    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        updateActiveQueueTabContext { $0.searchText = text }
        syncSelectionForVisibleInvoices()
    }

    func setSelectedArtifactIDs(_ ids: Set<PhysicalArtifact.ID>) {
        guard ids != selectedArtifactIDs else { return }
        updateActiveQueueTabContext { $0.selectedArtifactIDs = ids }

        guard !isSynchronizingSelection else { return }
        setSelectedArtifactID(visibleArtifacts.first(where: { ids.contains($0.id) })?.id)
    }

    func setSelectedArtifactID(_ id: PhysicalArtifact.ID?) {
        guard id != selectedArtifactID else { return }
        updateActiveQueueTabContext { $0.selectedArtifactID = id }
    }

    func selectNextArtifact() {
        let list = sortedVisibleArtifacts
        guard let currentID = selectedArtifactID,
              let idx = list.firstIndex(where: { $0.id == currentID }),
              idx + 1 < list.count else { return }
        let nextID = list[idx + 1].id
        setSelectedArtifactIDs([nextID])
    }

    private var sortedVisibleArtifacts: [PhysicalArtifact] {
        let descriptors = activeBrowserContext.sortDescriptors
        let ocrStates = ocrStatesByArtifactID
        let readStates = readStatesByArtifactID
        let metadata = documentMetadataByArtifactID

        return visibleArtifacts.sorted { lhs, rhs in
            for descriptor in descriptors {
                let result = compareBrowserColumn(
                    lhs, rhs,
                    columnID: descriptor.columnID,
                    ocrStates: ocrStates,
                    readStates: readStates,
                    metadata: metadata
                )
                if result != .orderedSame {
                    return descriptor.ascending
                        ? result == .orderedAscending
                        : result == .orderedDescending
                }
            }
            return lhs.addedAt > rhs.addedAt
        }
    }

    private func compareBrowserColumn(
        _ lhs: PhysicalArtifact,
        _ rhs: PhysicalArtifact,
        columnID: InvoiceBrowserColumnID,
        ocrStates: [PhysicalArtifact.ID: InvoiceOCRState],
        readStates: [PhysicalArtifact.ID: InvoiceReadState],
        metadata: [PhysicalArtifact.ID: DocumentMetadata]
    ) -> ComparisonResult {
        switch columnID {
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .addedAt:
            if lhs.addedAt == rhs.addedAt { return .orderedSame }
            return lhs.addedAt < rhs.addedAt ? .orderedAscending : .orderedDescending
        case .modifiedAt:
            if lhs.modifiedAt == rhs.modifiedAt { return .orderedSame }
            return lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending
        case .fileType:
            return lhs.fileType.rawValue.localizedCaseInsensitiveCompare(rhs.fileType.rawValue)
        case .vendor:
            return (metadata[lhs.id]?.vendor ?? "")
                .localizedCaseInsensitiveCompare(metadata[rhs.id]?.vendor ?? "")
        case .invoiceDate:
            let lhsDate = metadata[lhs.id]?.invoiceDate ?? lhs.addedAt
            let rhsDate = metadata[rhs.id]?.invoiceDate ?? rhs.addedAt
            if lhsDate == rhsDate { return .orderedSame }
            return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
        case .ocr:
            let lhsRank = ocrRank(ocrStates[lhs.id])
            let rhsRank = ocrRank(ocrStates[rhs.id])
            if lhsRank == rhsRank { return .orderedSame }
            return lhsRank < rhsRank ? .orderedAscending : .orderedDescending
        case .read:
            let lhsRank = readRank(readStates[lhs.id])
            let rhsRank = readRank(readStates[rhs.id])
            if lhsRank == rhsRank { return .orderedSame }
            return lhsRank < rhsRank ? .orderedAscending : .orderedDescending
        }
    }

    private func ocrRank(_ state: InvoiceOCRState?) -> Int {
        switch state ?? .waiting {
        case .success: return 0
        case .waiting: return 1
        case .failed: return 2
        }
    }

    private func readRank(_ state: InvoiceReadState?) -> Int {
        switch state ?? .waiting {
        case .success: return 0
        case .review: return 1
        case .waiting: return 2
        case .failed: return 3
        }
    }

    func setActiveBrowserSortDescriptors(_ descriptors: [InvoiceBrowserSortDescriptor]) {
        let resolvedDescriptors = resolvedInvoiceBrowserSortDescriptors(descriptors, for: selectedQueueTab)
        guard !invoiceBrowserSortDescriptorsMatch(activeBrowserContext.sortDescriptors, resolvedDescriptors) else {
            return
        }

        updateActiveQueueTabContext { context in
            context.browserContext.sortDescriptors = resolvedDescriptors
        }
    }

    func setActiveBrowserExpandedGroupIDs(_ expandedGroupIDs: Set<PhysicalArtifact.ID>) {
        guard expandedGroupIDs != activeBrowserContext.expandedGroupIDs else { return }
        updateActiveQueueTabContext { context in
            context.browserContext.expandedGroupIDs = expandedGroupIDs
        }
    }

    func setActiveBrowserContext(_ browserContext: InvoiceBrowserContext) {
        let resolvedContext = InvoiceBrowserContext(
            queueTab: selectedQueueTab,
            sortDescriptors: browserContext.sortDescriptors,
            expandedGroupIDs: browserContext.expandedGroupIDs
        )
        guard resolvedContext != activeBrowserContext else { return }
        updateActiveQueueTabContext { $0.browserContext = resolvedContext }
    }

    func hasExtractedText(for invoice: PhysicalArtifact) async -> Bool {
        guard let contentHash = invoice.contentHash else { return false }
        return await computationCache.hasCachedText(forContentHash: contentHash)
    }

    func extractedTextRecord(for invoice: PhysicalArtifact) -> InvoiceTextRecord? {
        guard let contentHash = invoice.contentHash else { return nil }
        return computationCache.textRecord(forContentHash: contentHash)
    }

    func hasStructuredData(for invoice: PhysicalArtifact) async -> Bool {
        guard let contentHash = invoice.contentHash else { return false }
        return await computationCache.hasCachedStructuredData(forContentHash: contentHash)
    }

    func updateLLMProvider(_ provider: LLMProvider) {
        guard llmSettings.provider != provider else { return }

        llmSettings.provider = provider
        llmSettings.baseURL = provider.defaultBaseURL
        if llmSettings.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            llmSettings.modelName = provider.defaultModelName
        }
        if provider == .lmStudio {
            llmSettings.apiKey = ""
        }

        structuredFailedHashes = []
        llmPreflightStatus = Self.initialLLMPreflightStatus(for: llmSettings)
        persistLLMSettings()
    }

    func updateLLMBaseURL(_ baseURL: String) {
        guard llmSettings.baseURL != baseURL else { return }
        llmSettings.baseURL = baseURL
        structuredFailedHashes = []
        llmPreflightStatus = Self.initialLLMPreflightStatus(for: llmSettings)
        persistLLMSettings()
    }

    func updateLLMModelName(_ modelName: String) {
        guard llmSettings.modelName != modelName else { return }
        llmSettings.modelName = modelName
        structuredFailedHashes = []
        llmPreflightStatus = Self.initialLLMPreflightStatus(for: llmSettings)
        persistLLMSettings()
    }

    func updateOpenAIAPIKey(_ apiKey: String) {
        guard llmSettings.apiKey != apiKey else { return }
        llmSettings.apiKey = apiKey
        structuredFailedHashes = []
        llmPreflightStatus = Self.initialLLMPreflightStatus(for: llmSettings)
        persistLLMSettings()
    }

    func updateLLMCustomInstructions(_ customInstructions: String) {
        guard llmSettings.customInstructions != customInstructions else { return }
        llmSettings.customInstructions = customInstructions
        structuredFailedHashes = []
        llmPreflightStatus = Self.initialLLMPreflightStatus(for: llmSettings)
        persistLLMSettings()
    }

    func checkLLMConnection() {
        Task { @MainActor in
            structuredFailedHashes = []
            llmPreflightStatus = await structuredExtractionClient.preflightCheck(settings: llmSettings)
            guard llmPreflightStatus.isReady else { return }
            await enqueueStructuredExtraction(for: invoices)
        }
    }

    func pickFolder(for role: FolderRole) {
        let existingURL = folderSettings.url(for: role)
        let title = "Choose \(role.rawValue) Folder"

        guard let selectedURL = FolderPicker.pickFolder(title: title, startingAt: existingURL) else {
            return
        }

        folderSettings.setURL(selectedURL, for: role)
        persistFolderSettings()
        settingsErrorMessage = nil
        fileSystemReconciler.updateConfiguration(folderSettings: folderSettings, autoRefresh: true)
    }

    func clearFolder(for role: FolderRole) {
        folderSettings.setURL(nil, for: role)
        persistFolderSettings()
        fileSystemReconciler.updateConfiguration(folderSettings: folderSettings, autoRefresh: true)
    }

    func refreshLibrary() {
        fileSystemReconciler.refreshNow()
    }

    /// Imports files dropped onto the Unprocessed view (from Finder/Desktop or
    /// resolved Mail attachments) by copying them into the inbox folder.
    func importDroppedFiles(at sourceURLs: [URL]) {
        guard !sourceURLs.isEmpty else { return }
        guard let inboxURL = folderSettings.inboxURL else {
            settingsErrorMessage = "Choose an Inbox folder in Settings before adding files."
            return
        }

        Task {
            let result: InboxImportService.ImportResult
            do {
                result = try await Task.detached {
                    try InboxImportService.importFiles(sourceURLs, into: inboxURL)
                }.value
            } catch {
                settingsErrorMessage = "Couldn't add dropped files: \(error.localizedDescription)"
                return
            }

            guard result.didImportAnything else { return }

            await fileSystemReconciler.reconcileNow()

            selectedQueueTab = .unprocessed
            let importedIDs = Set(result.importedURLs.compactMap { url in
                invoices.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }?.id
            })
            if !importedIDs.isEmpty {
                setSelection(ids: importedIDs, primary: importedIDs.first)
            }
        }
    }

    func runStartupHEICConversionCheckIfNeeded() {
        guard !didRunStartupHEICCheck else { return }
        didRunStartupHEICCheck = true
        guard let inboxURL = folderSettings.inboxURL else { return }
        guard let heicFiles = try? HEICConversionService.heicFiles(in: inboxURL),
              !heicFiles.isEmpty else { return }

        ensureHEICConversionSettingsConfiguredIfNeeded(heicCount: heicFiles.count)
        guard heicConversionSettings.autoConvertEnabled else { return }
        enqueueManualHEICConversion(heicFiles)
    }

    func revealConvertedFileInQueue(_ convertedFile: HEICConvertedFile) {
        if selectArtifactForConvertedFile(at: convertedFile.convertedURL) {
            return
        }

        Task {
            await fileSystemReconciler.reconcileNow()
            _ = selectArtifactForConvertedFile(at: convertedFile.convertedURL)
        }
    }

    func markHEICConversionActivitySeen() {
        heicConversionQueue.markActivitySeen()
    }

    func updateHEICAutoConvertEnabled(_ enabled: Bool) {
        guard heicConversionSettings.autoConvertEnabled != enabled else { return }
        heicConversionSettings.autoConvertEnabled = enabled
        heicConversionSettings.hasUserConfigured = true
        persistHEICConversionSettings()
    }

    func updateHEICOriginalFileHandling(_ handling: HEICOriginalFileHandling) {
        guard heicConversionSettings.originalFileHandling != handling else { return }
        heicConversionSettings.originalFileHandling = handling
        heicConversionSettings.hasUserConfigured = true
        persistHEICConversionSettings()
    }

    func moveSelectedToInProgress() {
        let orderedSelectedIDs = visibleArtifacts
            .map(\.id)
            .filter { selectedArtifactIDs.contains($0) }
        moveInvoicesToInProgress(ids: orderedSelectedIDs)
    }

    func archiveInvoices(ids: [PhysicalArtifact.ID]) async {
        metadataFlushGuard?()
        pendingPreferredSelectionID = nil

        guard let archiveRoot = folderSettings.duplicatesURL else {
            settingsErrorMessage = "Choose an Archive folder before archiving invoices."
            return
        }

        let documents = resolveDocuments(for: ids)
        guard !documents.isEmpty else { return }

        let allArtifactIDs = documents.flatMap(\.artifactIDs)
        applyOptimisticDeparture(of: Set(allArtifactIDs)) { removedIDs in
            optimisticallyRemoveArtifacts(ids: removedIDs)
        }
        let archivedContentHashes = Set(allArtifactIDs.compactMap { id in
            invoices.first { $0.id == id }?.contentHash
        })
        let remainingContentHashes = Set(
            invoices
                .filter { !Set(allArtifactIDs).contains($0.id) }
                .compactMap { $0.contentHash }
        )
        let orphanedContentHashes = archivedContentHashes.subtracting(remainingContentHashes)

        do {
            let lookup = artifactsByID
            let result = try workflowActionCoordinator.moveToArchive(
                documents: documents,
                artifactsByID: lookup,
                workflowsByID: workflowByID,
                archiveRoot: archiveRoot
            )
            workflowByID = result.workflowsByID
            persistWorkflow()

            if !orphanedContentHashes.isEmpty {
                await computationCache.invalidate(contentHashes: orphanedContentHashes)
                syncComputationHashes()
                textPendingHashes.subtract(orphanedContentHashes)
                textFailedHashes.subtract(orphanedContentHashes)
                structuredPendingHashes.subtract(orphanedContentHashes)
                structuredFailedHashes.subtract(orphanedContentHashes)
            }

            fileSystemReconciler.suppressWatcherRefresh(for: 1.5)
            settingsErrorMessage = nil
            await fileSystemReconciler.reconcileNow()
        } catch {
            pendingPreferredSelectionID = nil
            settingsErrorMessage = error.localizedDescription
        }
    }

    func deleteInvoicesToTrash(ids: [PhysicalArtifact.ID]) async {
        metadataFlushGuard?()
        pendingPreferredSelectionID = nil

        var seenURLs: Set<URL> = []
        let selectedArtifacts = ids.compactMap { artifactID -> PhysicalArtifact? in
            guard let artifact = invoices.first(where: { $0.id == artifactID }),
                  accessCoordinator.fileExists(for: artifact.handle),
                  seenURLs.insert(artifact.fileURL.standardizedFileURL).inserted else {
                return nil
            }
            return artifact
        }

        guard !selectedArtifacts.isEmpty else {
            NSSound.beep()
            return
        }

        let selectedIDs = Set(selectedArtifacts.map(\.id))
        applyOptimisticDeparture(of: selectedIDs) { removedIDs in
            optimisticallyRemoveArtifacts(ids: removedIDs)
        }
        let deletedContentHashes = Set(selectedArtifacts.compactMap(\.contentHash))
        let remainingContentHashes = Set(
            invoices
                .filter { !selectedIDs.contains($0.id) }
                .compactMap(\.contentHash)
        )
        let orphanedContentHashes = deletedContentHashes.subtracting(remainingContentHashes)

        do {
            for artifact in selectedArtifacts {
                try moveToTrashHandler(artifact.fileURL)
            }

            if !orphanedContentHashes.isEmpty {
                await computationCache.invalidate(contentHashes: orphanedContentHashes)
                syncComputationHashes()
                textPendingHashes.subtract(orphanedContentHashes)
                textFailedHashes.subtract(orphanedContentHashes)
                structuredPendingHashes.subtract(orphanedContentHashes)
                structuredFailedHashes.subtract(orphanedContentHashes)
            }

            fileSystemReconciler.suppressWatcherRefresh(for: 1.5)
            settingsErrorMessage = nil
            await fileSystemReconciler.reconcileNow()
        } catch {
            pendingPreferredSelectionID = nil
            settingsErrorMessage = error.localizedDescription
        }
    }

    /// Whether the given selection can be joined into a single multi-page PDF.
    /// Requires at least two artifacts that all live in the same inbox/processing folder.
    func canJoinArtifactsIntoPDF(ids: [PhysicalArtifact.ID]) -> Bool {
        let artifacts = ids.compactMap { id in invoices.first { $0.id == id } }
        guard artifacts.count >= 2, artifacts.count == ids.count else { return false }
        guard artifacts.allSatisfy({ $0.location == .inbox || $0.location == .processing }) else { return false }
        let folders = Set(artifacts.map { $0.fileURL.deletingLastPathComponent().standardizedFileURL.path })
        return folders.count == 1
    }

    /// Joins the selected artifacts (in the provided display order) into a single
    /// multi-page PDF in the same folder, then archives the original source files.
    func joinArtifactsIntoPDF(ids: [PhysicalArtifact.ID], fileName: String) async {
        metadataFlushGuard?()

        guard canJoinArtifactsIntoPDF(ids: ids) else {
            settingsErrorMessage = "Select two or more files from the same queue to join them into a PDF."
            return
        }
        guard let archiveRoot = folderSettings.duplicatesURL else {
            settingsErrorMessage = "Choose an Archive folder before joining documents."
            return
        }

        let orderedArtifacts = ids.compactMap { id in invoices.first { $0.id == id } }
        guard let firstArtifact = orderedArtifacts.first else { return }

        let destinationFolder = firstArtifact.fileURL.deletingLastPathComponent()
        let destinationURL = Self.uniqueJoinedPDFURL(in: destinationFolder, preferredFileName: fileName)
        let sources = orderedArtifacts.map { PDFJoinSource(fileURL: $0.fileURL, fileType: $0.fileType) }

        do {
            try await Task.detached(priority: .userInitiated) {
                try PDFJoinService.join(sources: sources, to: destinationURL)
            }.value
        } catch {
            settingsErrorMessage = error.localizedDescription
            return
        }

        _ = PhysicalArtifactIdentityStore.shared.id(for: destinationURL)
        PhysicalArtifactIdentityStore.shared.save()

        let joinedContentHashes = Set(orderedArtifacts.compactMap { $0.contentHash })
        let remainingContentHashes = Set(
            invoices
                .filter { !ids.contains($0.id) }
                .compactMap { $0.contentHash }
        )
        let orphanedContentHashes = joinedContentHashes.subtracting(remainingContentHashes)

        do {
            let result = try workflowActionCoordinator.moveArtifactsToArchive(
                artifacts: orderedArtifacts,
                workflowsByID: workflowByID,
                archiveRoot: archiveRoot
            )
            workflowByID = result.workflowsByID
            persistWorkflow()

            if !orphanedContentHashes.isEmpty {
                await computationCache.invalidate(contentHashes: orphanedContentHashes)
                syncComputationHashes()
                textPendingHashes.subtract(orphanedContentHashes)
                textFailedHashes.subtract(orphanedContentHashes)
                structuredPendingHashes.subtract(orphanedContentHashes)
                structuredFailedHashes.subtract(orphanedContentHashes)
            }

            fileSystemReconciler.suppressWatcherRefresh(for: 1.5)
            settingsErrorMessage = nil
            let joinedArtifactID = PhysicalArtifactIdentityStore.shared.existingID(for: destinationURL)
            setSelection(ids: Set(joinedArtifactID.map { [$0] } ?? []), primary: joinedArtifactID)
            await fileSystemReconciler.reconcileNow()
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    /// Whether the given selection can be split into a separate copy: exactly one
    /// unprocessed/in-progress file with a known content hash.
    func canDuplicateForSeparateProcessing(ids: [PhysicalArtifact.ID]) -> Bool {
        guard ids.count == 1, let artifact = invoices.first(where: { $0.id == ids[0] }) else {
            return false
        }
        return (artifact.location == .inbox || artifact.location == .processing)
            && artifact.contentHash != nil
    }

    /// Creates an independently-processable copy of a file (e.g. for a second receipt captured
    /// in the same image). The copy carries a unique metadata marker so it has a distinct
    /// content hash, and is recorded as "not a duplicate" of the original so the visually
    /// identical pages are never regrouped by text/structured matching.
    func duplicateForSeparateProcessing(id: PhysicalArtifact.ID, fileName: String) async {
        metadataFlushGuard?()

        guard canDuplicateForSeparateProcessing(ids: [id]),
              let source = invoices.first(where: { $0.id == id }) else {
            settingsErrorMessage = "Only an unprocessed or in-progress file can be split into a separate copy."
            return
        }

        let sourceURL = source.fileURL
        let destinationFolder = sourceURL.deletingLastPathComponent()
        let fileExtension = sourceURL.pathExtension
        let destinationURL = Self.uniqueCopyURL(
            in: destinationFolder,
            preferredFileName: fileName,
            fileExtension: fileExtension
        )
        let fileType = source.fileType

        do {
            try await Task.detached(priority: .userInitiated) {
                try FileDuplicationService.duplicate(source: sourceURL, to: destinationURL, fileType: fileType)
            }.value
        } catch {
            settingsErrorMessage = error.localizedDescription
            return
        }

        let newHash = try? FileHasher.sha256(for: destinationURL)
        if let originalHash = source.contentHash, let newHash, newHash != originalHash {
            separatedContentHashPairs.insert(ContentHashPair(originalHash, newHash))
            DuplicateOverrideStore.save(separatedContentHashPairs)
        }

        _ = PhysicalArtifactIdentityStore.shared.id(for: destinationURL)
        PhysicalArtifactIdentityStore.shared.save()

        fileSystemReconciler.suppressWatcherRefresh(for: 1.5)
        settingsErrorMessage = nil
        let copyArtifactID = PhysicalArtifactIdentityStore.shared.existingID(for: destinationURL)
        setSelection(ids: Set(copyArtifactID.map { [$0] } ?? []), primary: copyArtifactID)
        await fileSystemReconciler.reconcileNow()
    }

    private static func uniqueCopyURL(in folder: URL, preferredFileName: String, fileExtension: String) -> URL {
        let trimmed = preferredFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixToDrop = "." + fileExtension.lowercased()
        let baseCandidate: String
        if trimmed.isEmpty {
            baseCandidate = "Copy"
        } else if !fileExtension.isEmpty, trimmed.lowercased().hasSuffix(suffixToDrop) {
            baseCandidate = String(trimmed.dropLast(suffixToDrop.count))
        } else {
            baseCandidate = trimmed
        }
        let sanitizedBase = baseCandidate.replacingOccurrences(of: "/", with: "-")

        let fileManager = FileManager.default
        func candidateURL(_ name: String) -> URL {
            let withName = folder.appendingPathComponent(name)
            return fileExtension.isEmpty ? withName : withName.appendingPathExtension(fileExtension)
        }

        var candidate = candidateURL(sanitizedBase)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var suffix = 2
        while true {
            candidate = candidateURL("\(sanitizedBase) \(suffix)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func uniqueJoinedPDFURL(in folder: URL, preferredFileName: String) -> URL {
        let trimmed = preferredFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if trimmed.isEmpty {
            baseName = "Joined Document"
        } else if trimmed.lowercased().hasSuffix(".pdf") {
            baseName = String(trimmed.dropLast(4))
        } else {
            baseName = trimmed
        }
        let sanitizedBase = baseName.replacingOccurrences(of: "/", with: "-")

        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent(sanitizedBase).appendingPathExtension("pdf")
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var suffix = 2
        while true {
            candidate = folder.appendingPathComponent("\(sanitizedBase) \(suffix)").appendingPathExtension("pdf")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    func rescanInvoices(ids: Set<PhysicalArtifact.ID>) async {
        await queueHandlerSetupTask?.value
        let selectedArtifacts = invoices.filter { ids.contains($0.id) }
        guard !selectedArtifacts.isEmpty else { return }

        let selectedArtifactsByDocumentID = Dictionary(grouping: selectedArtifacts, by: \.documentID)
        var invoicesToRescan: [PhysicalArtifact] = []
        var contentHashes: Set<String> = []

        for (documentID, documentInvoices) in selectedArtifactsByDocumentID {
            guard let document = librarySnapshot.documentsByID[documentID] else { continue }
            let selectedArtifactIDs = Set(documentInvoices.map(\.id))
            let documentArtifactIDs = document.artifactIDs
            let shouldClearDocumentMetadata = selectedArtifactIDs == documentArtifactIDs

            if shouldClearDocumentMetadata {
                clearDocumentMetadata(for: document.id)
                let rescannedArtifacts = invoices.filter { documentArtifactIDs.contains($0.id) }
                let rescannedHashes = Set(rescannedArtifacts.compactMap(\.contentHash))

                invoicesToRescan.append(contentsOf: rescannedArtifacts)
                contentHashes.formUnion(rescannedHashes)

                if !rescannedHashes.isEmpty {
                    rescannedDocumentContextsByID[document.id] = DocumentRescanContext(
                        documentID: document.id,
                        artifactIDs: documentArtifactIDs,
                        pendingContentHashes: rescannedHashes
                    )
                    for contentHash in rescannedHashes {
                        rescannedDocumentIDsByHash[contentHash, default: []].insert(document.id)
                    }
                }
            } else {
                invoicesToRescan.append(contentsOf: documentInvoices)
                contentHashes.formUnion(documentInvoices.compactMap(\.contentHash))
            }
        }

        guard !contentHashes.isEmpty else { return }

        await computationCache.invalidate(contentHashes: contentHashes)
        syncComputationHashes()
        textPendingHashes.subtract(contentHashes)
        textFailedHashes.subtract(contentHashes)
        structuredPendingHashes.subtract(contentHashes)
        structuredFailedHashes.subtract(contentHashes)
        rebuildLibrarySnapshot()

        let rescanRequests = textExtractionHandler.buildRequests(
            from: Array(Dictionary(uniqueKeysWithValues: invoicesToRescan.map { ($0.id, $0) }).values),
            force: true
        )
        await textExtractionQueue.enqueue(rescanRequests, excludingHashes: extractedTextHashes.union(textFailedHashes))
    }

    func moveInvoicesToInProgress(ids: Set<PhysicalArtifact.ID>) {
        let ordered = orderedProcessingIDs(requestedIDs: ids)
        moveInvoicesToInProgress(ids: ordered)
    }

    private func reopenProcessedToInProgress(ids: Set<PhysicalArtifact.ID>) {
        guard let processingRoot = folderSettings.processingURL else {
            settingsErrorMessage = "Choose a Processing folder before moving invoices into In Progress."
            return
        }

        let documents = resolveDocuments(for: ids) { $0.canReopenToInProgress }
        guard !documents.isEmpty else { return }
        let reopenedIDs = Set(documents.flatMap(\.artifactIDs))
        applyOptimisticDeparture(of: reopenedIDs) { movedIDs in
            optimisticallyRelocateArtifacts(ids: movedIDs, to: .processing, status: .inProgress)
        }

        do {
            let result = try workflowActionCoordinator.reopenToInProgress(
                documents: documents,
                artifactsByID: artifactsByID,
                workflowsByID: workflowByID,
                processingRoot: processingRoot
            )
            workflowByID = result.workflowsByID
            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToInProgress(ids: [PhysicalArtifact.ID]) {
        pendingPreferredSelectionID = nil

        let allIDs = Set(ids)
        let processedIDs = Set(invoices.filter { allIDs.contains($0.id) && $0.canReopenToInProgress }.map(\.id))
        if !processedIDs.isEmpty {
            reopenProcessedToInProgress(ids: processedIDs)
        }

        let inboxIDs = ids.filter { !processedIDs.contains($0) }
        guard !inboxIDs.isEmpty else { return }

        guard let processingRoot = folderSettings.processingURL else {
            settingsErrorMessage = "Choose a Processing folder before moving invoices into In Progress."
            return
        }
        guard let duplicatesRoot = folderSettings.duplicatesURL else {
            settingsErrorMessage = "Choose an Archive folder before moving invoices into In Progress."
            return
        }

        let documents = resolveDocuments(for: inboxIDs) { $0.canMoveToInProgress }
        guard !documents.isEmpty else { return }
        let movedToInProgressIDs = Set(documents.flatMap(\.artifactIDs))
        applyOptimisticDeparture(of: movedToInProgressIDs) { movedIDs in
            optimisticallyRelocateArtifacts(ids: movedIDs, to: .processing, status: .inProgress)
        }

        do {
            let result = try workflowActionCoordinator.moveToInProgress(
                documents: documents,
                artifactsByID: artifactsByID,
                workflowsByID: workflowByID,
                processingRoot: processingRoot,
                duplicatesRoot: duplicatesRoot,
                structuredRecordForContentHash: { [computationCache] contentHash in
                    computationCache.structuredRecord(forContentHash: contentHash)
                }
            )
            workflowByID = result.workflowsByID
            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
        } catch {
            pendingPreferredSelectionID = nil
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToUnprocessed(ids: Set<PhysicalArtifact.ID>) {
        metadataFlushGuard?()
        pendingPreferredSelectionID = nil

        guard !ids.isEmpty else { return }
        guard let inboxRoot = folderSettings.inboxURL else {
            settingsErrorMessage = "Choose an Inbox folder before moving invoices back to Unprocessed."
            return
        }

        let documents = resolveDocuments(for: ids) { $0.location == .processing }
        guard !documents.isEmpty else { return }
        let movedToUnprocessedIDs = Set(documents.flatMap(\.artifactIDs))
        applyOptimisticDeparture(of: movedToUnprocessedIDs) { movedIDs in
            optimisticallyRelocateArtifacts(ids: movedIDs, to: .inbox, status: .unprocessed)
        }

        do {
            let result = try workflowActionCoordinator.moveToUnprocessed(
                documents: documents,
                artifactsByID: artifactsByID,
                workflowsByID: workflowByID,
                inboxRoot: inboxRoot
            )
            workflowByID = result.workflowsByID
            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
        } catch {
            pendingPreferredSelectionID = nil
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToProcessed(ids: Set<PhysicalArtifact.ID>) {
        metadataFlushGuard?()
        pendingPreferredSelectionID = nil

        guard !ids.isEmpty else { return }
        guard let processedRoot = folderSettings.processedURL else {
            settingsErrorMessage = "Choose a Processed folder before archiving invoices."
            return
        }

        let documents = resolveDocuments(for: ids) { $0.canMarkDone }
        guard !documents.isEmpty else { return }
        let movedToProcessedIDs = Set(documents.flatMap(\.artifactIDs))

        let allEligibleArtifactIDs = documents.flatMap(\.artifactIDs)
        guard allEligibleArtifactIDs.allSatisfy({
            !(documentMetadata(for: $0).vendor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) else {
            settingsErrorMessage = "Set a vendor before moving invoices to Processed."
            return
        }

        applyOptimisticDeparture(of: movedToProcessedIDs) { movedIDs in
            optimisticallyRelocateArtifacts(ids: movedIDs, to: .processed, status: .processed)
        }

        do {
            let result = try workflowActionCoordinator.moveToProcessed(
                documents: documents,
                artifactsByID: artifactsByID,
                workflowsByID: workflowByID,
                processedRoot: processedRoot
            )
            workflowByID = result.workflowsByID
            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
        } catch {
            pendingPreferredSelectionID = nil
            settingsErrorMessage = error.localizedDescription
        }
    }

    /// Closure invoked before any move operation to flush buffered metadata edits.
    /// Set by the view layer (InvoiceDetailView) to drain the editing context.
    var metadataFlushGuard: (() -> Void)?

    func drainPendingRenames() async {
        await filenameReconciler.drain()
        workflowPersister.flush()
    }

    func applyBufferedMetadata(_ metadata: DocumentMetadata, for artifactID: PhysicalArtifact.ID) {
        guard let document = librarySnapshot.document(for: artifactID),
              document.metadata != metadata else {
            return
        }
        updateWorkflowMetadata(metadata, for: document.id)
    }

    func updateWorkflowMetadata(_ metadata: DocumentMetadata, for documentID: Document.ID) {
        guard let document = librarySnapshot.documentsByID[documentID] else { return }
        let artifacts = invoices.filter { document.artifactIDs.contains($0.id) }

        for artifact in artifacts {
            let existingWorkflow = workflowByID[artifact.id]
            workflowByID[artifact.id] = StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: metadata.isEmpty ? nil : .document
            )

            if artifact.location == .processing {
                Task { [filenameReconciler] in
                    await filenameReconciler.schedule(FilenameIntent(
                        artifactID: artifact.id,
                        currentURL: artifact.fileURL,
                        vendor: metadata.vendor,
                        invoiceDate: metadata.invoiceDate,
                        invoiceNumber: metadata.invoiceNumber,
                        fileType: artifact.fileType
                    ))
                }
            }
        }

        workflowPersister.scheduleSave()
        rebuildLibrarySnapshot()
    }

    func updateVendor(_ vendor: String, for artifactID: PhysicalArtifact.ID) {
        guard invoices.first(where: { $0.id == artifactID })?.location == .processing else {
            return
        }

        let trimmedVendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVendor = trimmedVendor.isEmpty ? nil : trimmedVendor
        guard let document = librarySnapshot.document(for: artifactID),
              document.metadata.vendor != normalizedVendor else {
            return
        }

        var metadata = document.metadata
        metadata.vendor = normalizedVendor
        updateWorkflowMetadata(metadata, for: document.id)
    }

    func updateInvoiceDate(_ invoiceDate: Date, for artifactID: PhysicalArtifact.ID) {
        guard let invoice = invoices.first(where: { $0.id == artifactID }),
              invoice.location == .processing else {
            return
        }

        guard let document = librarySnapshot.document(for: artifactID) else {
            return
        }

        let currentInvoiceDate = document.metadata.invoiceDate ?? invoice.addedAt
        guard currentInvoiceDate != invoiceDate else {
            return
        }

        var metadata = document.metadata
        metadata.invoiceDate = invoiceDate
        updateWorkflowMetadata(metadata, for: document.id)
    }

    func updateInvoiceNumber(_ invoiceNumber: String, for artifactID: PhysicalArtifact.ID) {
        guard let invoice = invoices.first(where: { $0.id == artifactID }),
              invoice.location == .processing || invoice.location == .processed else {
            return
        }

        let normalizedInvoiceNumber = normalizedInvoiceNumber(from: invoiceNumber)
        guard let document = librarySnapshot.document(for: artifactID),
              document.metadata.invoiceNumber != normalizedInvoiceNumber else {
            return
        }

        var metadata = document.metadata
        metadata.invoiceNumber = normalizedInvoiceNumber
        if invoice.location == .processing {
            updateWorkflowMetadata(metadata, for: document.id)
        } else {
            setDocumentMetadata(metadata, for: document.id)
        }
    }

    func updateDocumentType(_ documentType: DocumentType?, for artifactID: PhysicalArtifact.ID) {
        guard let invoice = invoices.first(where: { $0.id == artifactID }),
              invoice.location == .processing || invoice.location == .processed else {
            return
        }

        guard let document = librarySnapshot.document(for: artifactID),
              document.metadata.documentType != documentType else {
            return
        }

        var metadata = document.metadata
        metadata.documentType = documentType
        if invoice.location == .processing {
            updateWorkflowMetadata(metadata, for: document.id)
        } else {
            setDocumentMetadata(metadata, for: document.id)
        }
    }

    private func applyFilenameRenameResult(_ result: FilenameRenameResult) {
        guard let index = invoices.firstIndex(where: { $0.id == result.artifactID }) else {
            return
        }
        invoices[index].fileURL = result.newURL
        invoices[index].name = result.newName
        fileSystemReconciler.suppressWatcherRefresh(for: 1.0)
    }

    func persistPreviewRotation(for artifactID: PhysicalArtifact.ID, quarterTurns: Int) async -> PreviewRotationSaveResult? {
        guard let invoice = invoices.first(where: { $0.id == artifactID }) else {
            return nil
        }

        return await persistPreviewRotation(
            for: PreviewCommitRequest(invoice: invoice, quarterTurns: quarterTurns)
        )
    }

    /// Persists queued preview edits (page reorder and/or rotation) to disk, recomputes the
    /// content hash, and migrates caches so extraction pipelines are not needlessly restarted.
    /// Reorder is applied before rotation so the requested order is preserved.
    func persistPreviewRotation(for request: PreviewCommitRequest) async -> PreviewRotationSaveResult? {
        let rotation = normalizePreviewRotation(request.quarterTurns)
        let pageOrder = request.pageOrder
        guard rotation != 0 || pageOrder != nil,
              let invoice = resolvedInvoice(for: request) else {
            return nil
        }

        let handle = invoice.handle

        guard accessCoordinator.fileExists(for: handle) else {
            return nil
        }

        do {
            if let pageOrder {
                try await accessCoordinator.reorderPages(handle: handle, order: pageOrder)
            }

            if rotation != 0 {
                try await accessCoordinator.rotate(handle: handle, quarterTurns: rotation)
            }

            let updatedContentHash = accessCoordinator.updatedContentHash(for: handle)
            await migrateCachedArtifacts(from: invoice.contentHash, to: updatedContentHash)
            fileSystemReconciler.suppressWatcherRefresh(for: 1.5)

            if let refreshedIndex = invoices.firstIndex(where: { $0.id == invoice.id }) {
                invoices[refreshedIndex].contentHash = updatedContentHash ?? invoices[refreshedIndex].contentHash
            }

            rebuildLibrarySnapshot()
            settingsErrorMessage = nil
            return PreviewRotationSaveResult(contentHash: updatedContentHash)
        } catch {
            settingsErrorMessage = error.localizedDescription
            return nil
        }
    }

    func convertSelectedHEIC() {
        try? updateSelectedInvoice { invoice in
            guard invoice.fileType == .heic else { return }
            invoice.fileType = .jpeg
        }
    }

    private func updateSelectedInvoice(_ transform: (inout PhysicalArtifact) throws -> Void) throws {
        guard let selectedArtifactID,
              let index = invoices.firstIndex(where: { $0.id == selectedArtifactID }) else {
            return
        }

        var updated = invoices[index]
        try transform(&updated)
        invoices[index] = updated
    }

    private func handleFileSystemReconciliation(_ result: Result<FileSystemReconciliationSnapshot, Error>) async {
        await queueHandlerSetupTask?.value

        switch result {
        case .success(let snapshot):
            await applyReconciledArtifacts(snapshot)
        case .failure(let error):
            librarySnapshot = .empty
            invoices = []
            documents = []
            documentMetadataHintsByArtifactID = [:]
            computationCache.reset()
            syncComputationHashes()
            textPendingHashes = []
            textFailedHashes = []
            structuredPendingHashes = []
            structuredFailedHashes = []
            setSelection(ids: [], primary: nil)
            settingsErrorMessage = error.localizedDescription
        }
    }

    private func applyReconciledArtifacts(_ snapshot: FileSystemReconciliationSnapshot) async {
        invoices = snapshot.artifacts
        documentMetadataHintsByArtifactID = snapshot.documentMetadataHintsByArtifactID
        pruneWorkflowState(using: snapshot.artifacts)
        settingsErrorMessage = nil
        await computationCache.loadAll()
        syncComputationHashes()
        rebuildLibrarySnapshot()
        syncSelectionForVisibleInvoices()

        let newlyDetectedHEICFiles = invoices
            .filter { $0.location == .inbox && $0.fileType == .heic }
            .map { invoice in
                HEICAutoCandidate(
                    fileURL: invoice.fileURL.standardizedFileURL,
                    modifiedAt: invoice.modifiedAt
                )
            }
        if !newlyDetectedHEICFiles.isEmpty {
            ensureHEICConversionSettingsConfiguredIfNeeded(heicCount: newlyDetectedHEICFiles.count)
        }
        guard heicConversionSettings.autoConvertEnabled else {
            let textRequests = textExtractionHandler.buildRequests(from: invoices)
            await textExtractionQueue.enqueue(textRequests, excludingHashes: extractedTextHashes.union(textFailedHashes))
            if canAttemptStructuredExtraction(with: llmSettings) {
                await enqueueStructuredExtraction(for: invoices)
            }
            return
        }

        heicConversionQueue.enqueueAutomaticallyDetected(
            newlyDetectedHEICFiles,
            originalHandling: heicConversionSettings.originalFileHandling,
            archiveRoot: folderSettings.duplicatesURL
        ) { outcome in
            if outcome.convertedCount > 0 {
                self.refreshLibrary()
            }
        }

        let textRequests = textExtractionHandler.buildRequests(from: invoices)
        await textExtractionQueue.enqueue(textRequests, excludingHashes: extractedTextHashes.union(textFailedHashes))
        if canAttemptStructuredExtraction(with: llmSettings) {
            await enqueueStructuredExtraction(for: invoices)
        }
    }

    private func pruneWorkflowState(using loadedInvoices: [PhysicalArtifact]) {
        let activeWorkflowIDs = Set(loadedInvoices.map(\.id))
        let previousKeys = Set(workflowByID.keys)
        let staleKeys = previousKeys.subtracting(activeWorkflowIDs)

        guard !staleKeys.isEmpty else { return }
        staleKeys.forEach { workflowByID.removeValue(forKey: $0) }
        persistWorkflow()
    }

    private func persistWorkflow() {
        InvoiceWorkflowStore.save(workflowByID)
    }

    private static func migrateWorkflowKeysIfNeeded(_ workflows: [String: StoredInvoiceWorkflow]) -> [String: StoredInvoiceWorkflow] {
        guard !workflows.isEmpty else { return workflows }
        let needsMigration = workflows.keys.contains(where: PhysicalArtifactIdentityStore.isLegacyPathKey)
        guard needsMigration else { return workflows }

        let store = PhysicalArtifactIdentityStore.shared
        var migrated: [String: StoredInvoiceWorkflow] = [:]
        for (key, workflow) in workflows {
            let uuid = PhysicalArtifactIdentityStore.isLegacyPathKey(key) ? store.id(forPath: key) : key
            migrated[uuid] = workflow
        }
        store.save()
        InvoiceWorkflowStore.save(migrated)
        return migrated
    }

    private var activeQueueTabContext: QueueTabContext {
        queueScreenContext.activeTabContext
    }

    private func updateQueueScreenContext(_ transform: (inout QueueScreenContext) -> Void) {
        var nextContext = queueScreenContext
        transform(&nextContext)
        queueScreenContext = nextContext
    }

    private func updateActiveQueueTabContext(_ transform: (inout QueueTabContext) -> Void) {
        updateQueueTabContext(for: selectedQueueTab, transform)
    }

    private func updateQueueTabContext(
        for tab: InvoiceQueueTab,
        _ transform: (inout QueueTabContext) -> Void
    ) {
        updateQueueScreenContext { context in
            context.updateContext(for: tab, transform)
        }
    }

    private func rebuildLibrarySnapshot() {
        librarySnapshot = snapshotBuilder.build(
            from: invoices,
            workflowsByArtifactID: workflowByID,
            documentMetadataHintsByArtifactID: documentMetadataHintsByArtifactID,
            duplicateTermFrequenciesByHash: computationCache.duplicateTermFrequenciesByHash,
            duplicateFirstPageTermFrequenciesByHash: computationCache.firstPageDuplicateTermFrequenciesByHash,
            separatedContentHashPairs: separatedContentHashPairs
        )
        invoices = librarySnapshot.artifacts
        documents = librarySnapshot.documents
    }

    /// Records a user override declaring the given artifacts to be distinct documents, so the
    /// duplicate detector never groups them again. Separates the selected artifacts from each
    /// other and from the other members of any duplicate group they currently belong to, while
    /// preserving genuine duplicate relationships among the *unselected* members.
    func markArtifactsAsNotDuplicates(ids: [PhysicalArtifact.ID]) {
        let selectedIDs = Set(ids)
        guard !selectedIDs.isEmpty else { return }

        let hashByID = Dictionary(
            invoices.compactMap { invoice -> (PhysicalArtifact.ID, String)? in
                guard let hash = invoice.contentHash else { return nil }
                return (invoice.id, hash)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let selectedHashes = Set(selectedIDs.compactMap { hashByID[$0] })
        guard !selectedHashes.isEmpty else { return }

        var otherHashes: Set<String> = []
        for document in documents where document.isDuplicate {
            guard !document.artifactIDs.isDisjoint(with: selectedIDs) else { continue }
            for reference in document.artifacts where !selectedIDs.contains(reference.id) {
                if let hash = reference.contentHash {
                    otherHashes.insert(hash)
                }
            }
        }
        otherHashes.subtract(selectedHashes)

        var newPairs: Set<ContentHashPair> = []

        let selectedArray = Array(selectedHashes)
        for i in selectedArray.indices {
            for j in (i + 1)..<selectedArray.count {
                newPairs.insert(ContentHashPair(selectedArray[i], selectedArray[j]))
            }
        }

        for selected in selectedHashes {
            for other in otherHashes {
                newPairs.insert(ContentHashPair(selected, other))
            }
        }

        let additions = newPairs.subtracting(separatedContentHashPairs)
        guard !additions.isEmpty else { return }

        separatedContentHashPairs.formUnion(additions)
        DuplicateOverrideStore.save(separatedContentHashPairs)
        rebuildLibrarySnapshot()
    }

    private func syncSelectionForVisibleInvoices() {
        let preferredSelectionID = pendingPreferredSelectionID
        pendingPreferredSelectionID = nil

        let visible = visibleArtifacts
        guard !visible.isEmpty else {
            setSelection(ids: [], primary: nil)
            return
        }

        let visibleIDs = Set(visible.map(\.id))
        let retainedSelection = selectedArtifactIDs.intersection(visibleIDs)

        if let selectedArtifactID, visibleIDs.contains(selectedArtifactID) {
            let nextSelection = retainedSelection.isEmpty ? [selectedArtifactID] : retainedSelection
            setSelection(ids: nextSelection, primary: selectedArtifactID)
            return
        }

        if let primary = visible.first(where: { retainedSelection.contains($0.id) })?.id {
            setSelection(ids: retainedSelection, primary: primary)
            return
        }

        if let preferredSelectionID,
           visibleIDs.contains(preferredSelectionID) {
            setSelection(ids: [preferredSelectionID], primary: preferredSelectionID)
            return
        }

        guard let first = visible.first?.id else { return }
        setSelection(ids: [first], primary: first)
    }

    private func setSelection(ids: Set<PhysicalArtifact.ID>, primary: PhysicalArtifact.ID?) {
        isSynchronizingSelection = true
        selectedArtifactIDs = ids
        selectedArtifactID = primary
        isSynchronizingSelection = false
    }

    private func setPreferredSelectionAfterRemoving(ids removedIDs: Set<PhysicalArtifact.ID>) {
        guard !removedIDs.isEmpty else {
            pendingPreferredSelectionID = nil
            return
        }

        let orderedVisibleIDs = sortedVisibleArtifacts.map(\.id)
        guard !orderedVisibleIDs.isEmpty else {
            pendingPreferredSelectionID = nil
            return
        }

        let anchorID = selectedArtifactID
            ?? orderedVisibleIDs.first(where: { selectedArtifactIDs.contains($0) })
            ?? orderedVisibleIDs.first

        guard let anchorID,
              let anchorIndex = orderedVisibleIDs.firstIndex(of: anchorID) else {
            pendingPreferredSelectionID = nil
            return
        }

        let remainingIDs = orderedVisibleIDs.filter { !removedIDs.contains($0) }
        guard !remainingIDs.isEmpty else {
            pendingPreferredSelectionID = nil
            return
        }

        let replacementIndex = min(anchorIndex, remainingIDs.count - 1)
        pendingPreferredSelectionID = remainingIDs[replacementIndex]
    }

    private func applyPendingPreferredSelection() {
        if let pendingPreferredSelectionID {
            setSelection(ids: [pendingPreferredSelectionID], primary: pendingPreferredSelectionID)
        } else {
            setSelection(ids: [], primary: nil)
        }
    }

    private func applyOptimisticDeparture(
        of ids: Set<PhysicalArtifact.ID>,
        mutation: (Set<PhysicalArtifact.ID>) -> Void
    ) {
        guard !ids.isEmpty else { return }
        setPreferredSelectionAfterRemoving(ids: ids)
        applyPendingPreferredSelection()
        mutation(ids)
    }

    private func optimisticallyRelocateArtifacts(
        ids: Set<PhysicalArtifact.ID>,
        to location: InvoiceLocation,
        status: InvoiceStatus
    ) {
        guard !ids.isEmpty else { return }

        var didChange = false
        for index in invoices.indices where ids.contains(invoices[index].id) {
            invoices[index].location = location
            invoices[index].status = status
            invoices[index].processedAt = (location == .processed) ? .now : nil
            didChange = true
        }

        guard didChange else { return }
        rebuildLibrarySnapshot()
    }

    private func optimisticallyRemoveArtifacts(ids: Set<PhysicalArtifact.ID>) {
        guard !ids.isEmpty else { return }
        let previousCount = invoices.count
        invoices.removeAll { ids.contains($0.id) }
        guard invoices.count != previousCount else { return }
        rebuildLibrarySnapshot()
    }

    private func migrateCachedArtifacts(from previousContentHash: String?, to updatedContentHash: String?) async {
        guard let previousContentHash,
              let updatedContentHash,
              previousContentHash != updatedContentHash else {
            return
        }

        await computationCache.migrate(from: previousContentHash, to: updatedContentHash)
        remapHashState(from: previousContentHash, to: updatedContentHash)
    }

    private func remapHashState(from previousContentHash: String, to updatedContentHash: String) {
        syncComputationHashes()
        if textPendingHashes.remove(previousContentHash) != nil {
            textPendingHashes.insert(updatedContentHash)
        }
        if textFailedHashes.remove(previousContentHash) != nil {
            textFailedHashes.insert(updatedContentHash)
        }
        if structuredPendingHashes.remove(previousContentHash) != nil {
            structuredPendingHashes.insert(updatedContentHash)
        }
        if structuredFailedHashes.remove(previousContentHash) != nil {
            structuredFailedHashes.insert(updatedContentHash)
        }
    }

    private func resolvedInvoice(for request: PreviewCommitRequest) -> PhysicalArtifact? {
        if let byID = invoices.first(where: { $0.id == request.invoiceID }) {
            return byID
        }

        if let byURL = invoices.first(where: { $0.fileURL == request.handle.fileURL }) {
            return byURL
        }

        if let contentHash = request.handle.contentHash,
           let relocated = invoices.first(where: {
               $0.contentHash == contentHash &&
               $0.addedAt == request.handle.addedAt &&
               $0.fileType == request.handle.fileType
           }) {
            return relocated
        }

        return nil
    }

    @discardableResult
    private func applyWorkflow(_ workflow: StoredInvoiceWorkflow, to invoiceID: PhysicalArtifact.ID) -> PhysicalArtifact.ID? {
        do {
            guard let result = try workflowActionCoordinator.applyWorkflow(
                workflow,
                to: invoiceID,
                artifacts: invoices,
                workflowsByID: workflowByID,
                selectedArtifactIDs: selectedArtifactIDs,
                selectedArtifactID: selectedArtifactID
            ) else {
                return nil
            }

            invoices = result.artifacts
            workflowByID = result.workflowsByID
            persistWorkflow()
            setSelection(ids: result.selectedArtifactIDs, primary: result.selectedArtifactID)
            rebuildLibrarySnapshot()
            return invoiceID
        } catch {
            settingsErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func normalizedInvoiceNumber(from invoiceNumber: String) -> String? {
        let trimmed = invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizePreviewRotation(_ value: Int) -> Int {
        let normalized = value % 4
        return normalized >= 0 ? normalized : normalized + 4
    }

    private var artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact] {
        Dictionary(uniqueKeysWithValues: invoices.map { ($0.id, $0) })
    }

    private func resolveDocuments(for artifactIDs: some Collection<PhysicalArtifact.ID>) -> [Document] {
        var seen: Set<Document.ID> = []
        var result: [Document] = []
        for artifactID in artifactIDs {
            guard let document = librarySnapshot.document(for: artifactID),
                  seen.insert(document.id).inserted else {
                continue
            }
            result.append(document)
        }
        return result
    }

    private func resolveDocuments(
        for artifactIDs: some Collection<PhysicalArtifact.ID>,
        where isEligible: (PhysicalArtifact) -> Bool
    ) -> [Document] {
        let eligibleIDs = Set(invoices.filter { artifactIDs.contains($0.id) && isEligible($0) }.map(\.id))
        return resolveDocuments(for: eligibleIDs)
    }

    private func orderedProcessingIDs(requestedIDs: Set<PhysicalArtifact.ID>) -> [PhysicalArtifact.ID] {
        let visibleOrderedIDs = visibleArtifacts
            .map(\.id)
            .filter { requestedIDs.contains($0) }
        let visibleOrderedSet = Set(visibleOrderedIDs)
        let remainingIDs = invoices
            .map(\.id)
            .filter { requestedIDs.contains($0) && !visibleOrderedSet.contains($0) }
        return visibleOrderedIDs + remainingIDs
    }

    private func persistFolderSettings() {
        let defaults = UserDefaults.standard
        defaults.set(folderSettings.inboxURL?.path, forKey: UserDefaultsKey.inboxPath)
        defaults.set(folderSettings.processedURL?.path, forKey: UserDefaultsKey.processedPath)
        defaults.set(folderSettings.processingURL?.path, forKey: UserDefaultsKey.processingPath)
        defaults.set(folderSettings.duplicatesURL?.path, forKey: UserDefaultsKey.duplicatesPath)
    }

    private func persistLLMSettings() {
        let defaults = UserDefaults.standard
        defaults.set(llmSettings.provider.rawValue, forKey: UserDefaultsKey.llmProvider)
        defaults.set(llmSettings.baseURL, forKey: UserDefaultsKey.llmBaseURL)
        defaults.set(llmSettings.modelName, forKey: UserDefaultsKey.llmModelName)
        defaults.set(llmSettings.apiKey, forKey: UserDefaultsKey.llmAPIKey)
        defaults.set(llmSettings.customInstructions, forKey: UserDefaultsKey.llmCustomInstructions)
    }

    private func persistHEICConversionSettings() {
        let defaults = UserDefaults.standard
        defaults.set(heicConversionSettings.autoConvertEnabled, forKey: UserDefaultsKey.heicAutoConvertEnabled)
        defaults.set(heicConversionSettings.originalFileHandling.rawValue, forKey: UserDefaultsKey.heicOriginalFileHandling)
        defaults.set(heicConversionSettings.hasUserConfigured, forKey: UserDefaultsKey.heicSettingsConfigured)
    }

    private static func loadFolderSettings() -> FolderSettings {
        let defaults = UserDefaults.standard
        return FolderSettings(
            inboxURL: defaults.string(forKey: UserDefaultsKey.inboxPath).map { URL(fileURLWithPath: $0) },
            processedURL: defaults.string(forKey: UserDefaultsKey.processedPath).map { URL(fileURLWithPath: $0) },
            processingURL: defaults.string(forKey: UserDefaultsKey.processingPath).map { URL(fileURLWithPath: $0) },
            duplicatesURL: defaults.string(forKey: UserDefaultsKey.duplicatesPath).map { URL(fileURLWithPath: $0) }
        )
    }

    private static func loadLLMSettings() -> LLMSettings {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: UserDefaultsKey.llmProvider)
            .flatMap(LLMProvider.init(rawValue:))
            ?? .lmStudio

        return LLMSettings(
            provider: provider,
            baseURL: defaults.string(forKey: UserDefaultsKey.llmBaseURL) ?? provider.defaultBaseURL,
            modelName: defaults.string(forKey: UserDefaultsKey.llmModelName) ?? provider.defaultModelName,
            apiKey: defaults.string(forKey: UserDefaultsKey.llmAPIKey) ?? "",
            customInstructions: defaults.string(forKey: UserDefaultsKey.llmCustomInstructions) ?? ""
        )
    }

    private static func loadHEICConversionSettings() -> HEICConversionSettings {
        let defaults = UserDefaults.standard
        let handling = defaults.string(forKey: UserDefaultsKey.heicOriginalFileHandling)
            .flatMap(HEICOriginalFileHandling.init(rawValue:))
            ?? HEICConversionSettings.default.originalFileHandling

        return HEICConversionSettings(
            autoConvertEnabled: defaults.object(forKey: UserDefaultsKey.heicAutoConvertEnabled) as? Bool
                ?? HEICConversionSettings.default.autoConvertEnabled,
            originalFileHandling: handling,
            hasUserConfigured: defaults.bool(forKey: UserDefaultsKey.heicSettingsConfigured)
        )
    }

    private static func initialLLMPreflightStatus(for settings: LLMSettings) -> LLMPreflightStatus {
        let trimmedBaseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty else {
            return LLMPreflightStatus(state: .misconfigured, message: "Configure an LLM server URL to enable structured extraction.")
        }

        guard !trimmedModel.isEmpty else {
            return LLMPreflightStatus(state: .misconfigured, message: "Choose an LLM model name to enable structured extraction.")
        }

        if settings.provider == .openAI,
           settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LLMPreflightStatus(state: .misconfigured, message: "Add an OpenAI API key to enable structured extraction.")
        }

        return LLMPreflightStatus(state: .ready, message: "\(settings.provider.rawValue) is configured. Use Check Connection to verify reachability.")
    }

    private func enqueueManualHEICConversion(_ heicFiles: [URL]) {
        heicConversionQueue.enqueueManual(
            heicFiles,
            originalHandling: heicConversionSettings.originalFileHandling,
            archiveRoot: folderSettings.duplicatesURL
        ) { outcome in
            if outcome.failedCount > 0 {
                self.settingsErrorMessage = "Converted \(outcome.convertedCount) of \(outcome.convertedCount + outcome.failedCount) HEIC files. Some files could not be converted."
            } else {
                self.settingsErrorMessage = nil
            }

            if outcome.convertedCount > 0 {
                self.refreshLibrary()
            }
        }
    }

    private func ensureHEICConversionSettingsConfiguredIfNeeded(heicCount: Int) {
        guard !heicConversionSettings.hasUserConfigured else { return }
        let configured = Self.presentHEICConversionSettingsPrompt(
            count: heicCount,
            initial: HEICConversionSettings(
                autoConvertEnabled: false,
                originalFileHandling: .delete,
                hasUserConfigured: true
            )
        )
        heicConversionSettings = configured
        persistHEICConversionSettings()
    }

    private static func presentHEICConversionSettingsPrompt(
        count: Int,
        initial: HEICConversionSettings
    ) -> HEICConversionSettings {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "1 HEIC file found in Unprocessed"
            : "\(count) HEIC files found in Unprocessed"
        alert.informativeText = "Configure HEIC conversion. You can change this later in Settings."
        alert.addButton(withTitle: "Save")
        alert.alertStyle = .informational
        let accessory = HEICConversionPromptAccessory(initial: initial)
        alert.accessoryView = accessory.view
        _ = alert.runModal()
        return accessory.settings
    }

    @discardableResult
    private func selectArtifactForConvertedFile(at fileURL: URL) -> Bool {
        let standardizedURL = fileURL.standardizedFileURL
        guard let artifact = invoices.first(where: { $0.fileURL.standardizedFileURL == standardizedURL }) else {
            return false
        }

        switch artifact.location {
        case .inbox:
            selectedQueueTab = .unprocessed
        case .processing:
            selectedQueueTab = .inProgress
        case .processed:
            selectedQueueTab = .processed
        }

        setSelection(ids: [artifact.id], primary: artifact.id)
        return true
    }

    private func canAttemptStructuredExtraction(with settings: LLMSettings) -> Bool {
        let trimmedBaseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBaseURL.isEmpty, !trimmedModel.isEmpty else {
            return false
        }

        if settings.provider == .openAI {
            return !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return true
    }

    private func enqueueStructuredExtraction(for invoices: [PhysicalArtifact], force: Bool = false) async {
        let cachedHashes = await computationCache.reloadStructuredRecords()
        syncComputationHashes()
        let structuredRequests = structuredExtractionHandler.buildRequests(from: invoices, settings: llmSettings, force: force)
        await structuredExtractionQueue.enqueue(structuredRequests, excludingHashes: cachedHashes.union(structuredFailedHashes))
    }

    private func handleExtractedTextSaved(_ contentHash: String) async {
        textPendingHashes.remove(contentHash)
        textFailedHashes.remove(contentHash)
        await computationCache.syncExtractedText(forContentHash: contentHash)
        syncComputationHashes()
        rebuildLibrarySnapshot()
        guard llmPreflightStatus.isReady || canAttemptStructuredExtraction(with: llmSettings) else {
            return
        }

        let matchingInvoices = invoices.filter { $0.contentHash == contentHash }
        guard !matchingInvoices.isEmpty else { return }

        await enqueueStructuredExtraction(for: matchingInvoices, force: true)
    }

    private func handleStructuredDataSaved(contentHash: String, record: InvoiceStructuredDataRecord) {
        structuredPendingHashes.remove(contentHash)
        structuredFailedHashes.remove(contentHash)
        computationCache.setStructuredRecord(record, forContentHash: contentHash)
        syncComputationHashes()
        handleRescannedDocumentContentHashCompleted(contentHash)
        rebuildLibrarySnapshot()
        applyStructuredDataIfNeeded(contentHash: contentHash, record: record)
    }

    private func applyStructuredDataIfNeeded(contentHash: String, record: InvoiceStructuredDataRecord) {
        let matchingInvoices = invoices.filter { $0.contentHash == contentHash }

        for invoice in matchingInvoices {
            guard let document = librarySnapshot.document(for: invoice.id) else { continue }
            let candidateMetadata: DocumentMetadata

            if document.artifacts.count == 1 {
                let metadata = document.metadata
                candidateMetadata = DocumentMetadata(
                    vendor: metadata.vendor ?? record.companyName,
                    invoiceDate: metadata.invoiceDate ?? record.invoiceDate,
                    invoiceNumber: metadata.invoiceNumber ?? normalizedInvoiceNumber(from: record.invoiceNumber ?? ""),
                    documentType: metadata.documentType ?? record.documentType
                )
            } else {
                guard let mergedMetadata = snapshotBuilder.inferredStructuredDocumentMetadata(for: document) else {
                    continue
                }

                let metadata = document.metadata
                candidateMetadata = DocumentMetadata(
                    vendor: metadata.vendor ?? mergedMetadata.vendor,
                    invoiceDate: metadata.invoiceDate ?? mergedMetadata.invoiceDate,
                    invoiceNumber: metadata.invoiceNumber ?? mergedMetadata.invoiceNumber,
                    documentType: metadata.documentType ?? mergedMetadata.documentType
                )
            }

            guard candidateMetadata != document.metadata else { continue }
            setDocumentMetadata(candidateMetadata, for: document.id)
        }
    }

    private func setDocumentMetadata(
        _ metadata: DocumentMetadata,
        for documentID: Document.ID
    ) {
        guard let document = librarySnapshot.documentsByID[documentID] else { return }
        let artifacts = invoices.filter { document.artifactIDs.contains($0.id) }

        for artifact in artifacts {
            let existingWorkflow = workflowByID[artifact.id]
            workflowByID[artifact.id] = StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: metadata.isEmpty ? nil : .document
            )
        }

        persistWorkflow()
        rebuildLibrarySnapshot()
    }

    private func clearDocumentMetadata(for documentID: Document.ID) {
        guard let document = librarySnapshot.documentsByID[documentID] else { return }

        for artifact in document.artifacts {
            let existingWorkflow = workflowByID[artifact.id]
            workflowByID[artifact.id] = StoredInvoiceWorkflow(
                vendor: nil,
                invoiceDate: nil,
                invoiceNumber: nil,
                documentType: nil,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: nil
            )
        }

        persistWorkflow()
        rebuildLibrarySnapshot()
    }

    private func handleRescannedDocumentContentHashCompleted(_ contentHash: String) {
        guard let documentIDs = rescannedDocumentIDsByHash.removeValue(forKey: contentHash) else {
            return
        }

        for documentID in documentIDs {
            guard var context = rescannedDocumentContextsByID[documentID] else { continue }
            context.pendingContentHashes.remove(contentHash)

            if context.pendingContentHashes.isEmpty {
                rescannedDocumentContextsByID.removeValue(forKey: documentID)
                finalizeRescannedDocument(context)
            } else {
                rescannedDocumentContextsByID[documentID] = context
            }
        }
    }

    private func finalizeRescannedDocument(_ context: DocumentRescanContext) {
        let metadata = mergedDocumentMetadata(for: context.artifactIDs)
        let artifacts = invoices.filter { context.artifactIDs.contains($0.id) }

        for artifact in artifacts {
            let existingWorkflow = workflowByID[artifact.id]
            workflowByID[artifact.id] = StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: metadata.isEmpty ? nil : .document
            )
        }

        persistWorkflow()
        rebuildLibrarySnapshot()
    }

    private func mergedDocumentMetadata(for artifactIDs: Set<PhysicalArtifact.ID>) -> DocumentMetadata {
        snapshotBuilder.mergedDocumentMetadata(for: artifactIDs, artifacts: invoices)
    }

    func reloadLibraryForTesting() async {
        await fileSystemReconciler.reconcileNow()
    }

    func waitForBackgroundTextExtractionForTesting() async {
        await textExtractionQueue.waitForIdle()
        await structuredExtractionQueue.waitForIdle()
    }

}

private struct DocumentRescanContext {
    let documentID: Document.ID
    let artifactIDs: Set<PhysicalArtifact.ID>
    var pendingContentHashes: Set<String>
}

@MainActor
private final class HEICConversionPromptAccessory: NSObject {
    let view: NSView
    private let autoConvertCheckbox: NSButton
    private let handlingLabel: NSTextField
    private let handlingPopup: NSPopUpButton

    var settings: HEICConversionSettings {
        let autoConvertEnabled = autoConvertCheckbox.state == .on
        let selectedHandling = HEICOriginalFileHandling(rawValue: handlingPopup.selectedItem?.representedObject as? String ?? "")
            ?? .delete
        return HEICConversionSettings(
            autoConvertEnabled: autoConvertEnabled,
            originalFileHandling: selectedHandling,
            hasUserConfigured: true
        )
    }

    init(initial: HEICConversionSettings) {
        autoConvertCheckbox = NSButton(checkboxWithTitle: "Autoconvert", target: nil, action: nil)
        autoConvertCheckbox.state = initial.autoConvertEnabled ? .on : .off

        handlingLabel = NSTextField(labelWithString: "On convert, original file")
        handlingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for handling in HEICOriginalFileHandling.allCases {
            handlingPopup.addItem(withTitle: handling.title)
            handlingPopup.lastItem?.representedObject = handling.rawValue
            if handling == initial.originalFileHandling {
                handlingPopup.select(handlingPopup.lastItem)
            }
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 72))
        autoConvertCheckbox.translatesAutoresizingMaskIntoConstraints = false
        handlingLabel.translatesAutoresizingMaskIntoConstraints = false
        handlingPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoConvertCheckbox)
        container.addSubview(handlingLabel)
        container.addSubview(handlingPopup)

        NSLayoutConstraint.activate([
            autoConvertCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            autoConvertCheckbox.topAnchor.constraint(equalTo: container.topAnchor),

            handlingLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            handlingLabel.topAnchor.constraint(equalTo: autoConvertCheckbox.bottomAnchor, constant: 10),

            handlingPopup.leadingAnchor.constraint(equalTo: handlingLabel.trailingAnchor, constant: 10),
            handlingPopup.firstBaselineAnchor.constraint(equalTo: handlingLabel.firstBaselineAnchor),
            handlingPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            handlingPopup.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            handlingPopup.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        view = container
        super.init()
        autoConvertCheckbox.target = self
        autoConvertCheckbox.action = #selector(autoConvertToggled(_:))
        applyAutoConvertEnabled(initial.autoConvertEnabled)
    }

    @objc private func autoConvertToggled(_ sender: NSButton) {
        applyAutoConvertEnabled(sender.state == .on)
    }

    private func applyAutoConvertEnabled(_ enabled: Bool) {
        handlingPopup.isEnabled = enabled
        handlingLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
    }
}

private enum UserDefaultsKey {
    static let inboxPath = "settings.inboxPath"
    static let processedPath = "settings.processedPath"
    static let processingPath = "settings.processingPath"
    static let duplicatesPath = "settings.duplicatesPath"
    static let llmProvider = "settings.llmProvider"
    static let llmBaseURL = "settings.llmBaseURL"
    static let llmModelName = "settings.llmModelName"
    static let llmAPIKey = "settings.llmAPIKey"
    static let llmCustomInstructions = "settings.llmCustomInstructions"
    static let heicAutoConvertEnabled = "settings.heicAutoConvertEnabled"
    static let heicOriginalFileHandling = "settings.heicOriginalFileHandling"
    static let heicSettingsConfigured = "settings.heicSettingsConfigured"
}
