import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var invoices: [PhysicalArtifact]
    @Published var queueScreenContext: QueueScreenContext
    @Published var folderSettings: FolderSettings
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

    private let accessCoordinator = ArtifactAccessCoordinator()
    private let openInPreviewHandler: ([URL]) -> Void
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
    private var documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata] = [:]
    private var rescannedDocumentContextsByID: [Document.ID: DocumentRescanContext] = [:]
    private var rescannedDocumentIDsByHash: [String: Set<Document.ID>] = [:]
    private var isSynchronizingSelection = false

    init(
        folderSettings: FolderSettings? = nil,
        workflowByID: [String: StoredInvoiceWorkflow]? = nil,
        textStore: any InvoiceTextStoring = InvoiceTextStore.shared,
        textExtractor: any DocumentTextExtracting = DocumentTextExtractor(),
        structuredDataStore: any InvoiceStructuredDataStoring = InvoiceStructuredDataStore.shared,
        structuredExtractionClient: any InvoiceStructuredExtractionClient = RoutedStructuredExtractionClient(),
        llmSettings: LLMSettings? = nil,
        autoRefresh: Bool = true,
        openInPreview: (([URL]) -> Void)? = nil
    ) {
        let resolvedFolderSettings = folderSettings ?? Self.loadFolderSettings()
        let resolvedLLMSettings = llmSettings ?? Self.loadLLMSettings()

        self.queueScreenContext = QueueScreenContext()
        self.folderSettings = resolvedFolderSettings
        self.llmSettings = resolvedLLMSettings
        self.workflowByID = workflowByID ?? InvoiceWorkflowStore.load()
        self.openInPreviewHandler = openInPreview ?? { urls in
            AppModel.systemOpenInPreview(urls)
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

    func duplicateSimilarities(for artifactID: PhysicalArtifact.ID, limit: Int = 5) -> [DuplicateSimilarity] {
        guard let artifact = invoices.first(where: { $0.id == artifactID }),
              let contentHash = artifact.contentHash,
              let artifactTokens = computationCache.duplicateTokens(forContentHash: contentHash) else {
            return []
        }

        return librarySnapshot.documents
            .filter { !$0.contains(artifactID: artifactID) }
            .compactMap { document in
                document.bestSimilarity(
                    to: artifactTokens,
                    tokensByArtifactID: librarySnapshot.duplicateTokenSetsByArtifactID,
                    threshold: duplicateSimilarityThreshold
                )
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
        DuplicateDetector.duplicateSimilarityThreshold
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

    func moveSelectedToInProgress() {
        let orderedSelectedIDs = visibleArtifacts
            .map(\.id)
            .filter { selectedArtifactIDs.contains($0) }
        moveInvoicesToInProgress(ids: orderedSelectedIDs)
    }

    func archiveInvoices(ids: [PhysicalArtifact.ID]) async {
        guard let archiveRoot = folderSettings.duplicatesURL else {
            settingsErrorMessage = "Choose an Archive folder before archiving invoices."
            return
        }

        let documents = resolveDocuments(for: ids)
        guard !documents.isEmpty else { return }

        let allArtifactIDs = documents.flatMap(\.artifactIDs)
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
            setSelection(ids: [], primary: nil)
            await fileSystemReconciler.reconcileNow()
        } catch {
            settingsErrorMessage = error.localizedDescription
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
            selectedArtifactIDs = result.selectedArtifactIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToInProgress(ids: [PhysicalArtifact.ID]) {
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
            selectedArtifactIDs = result.selectedArtifactIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToUnprocessed(ids: Set<PhysicalArtifact.ID>) {
        guard !ids.isEmpty else { return }
        guard let inboxRoot = folderSettings.inboxURL else {
            settingsErrorMessage = "Choose an Inbox folder before moving invoices back to Unprocessed."
            return
        }

        let documents = resolveDocuments(for: ids) { $0.location == .processing }
        guard !documents.isEmpty else { return }

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
            selectedArtifactIDs = result.selectedArtifactIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToProcessed(ids: Set<PhysicalArtifact.ID>) {
        guard !ids.isEmpty else { return }
        guard let processedRoot = folderSettings.processedURL else {
            settingsErrorMessage = "Choose a Processed folder before archiving invoices."
            return
        }

        let documents = resolveDocuments(for: ids) { $0.canMarkDone }
        guard !documents.isEmpty else { return }

        let allEligibleArtifactIDs = documents.flatMap(\.artifactIDs)
        guard allEligibleArtifactIDs.allSatisfy({
            !(documentMetadata(for: $0).vendor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) else {
            settingsErrorMessage = "Set a vendor before moving invoices to Processed."
            return
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
            selectedArtifactIDs = result.selectedArtifactIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func updateVendor(_ vendor: String, for artifactID: PhysicalArtifact.ID) {
        guard let invoice = invoices.first(where: { $0.id == artifactID }),
              invoice.location == .processing else {
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
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: true)
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
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: true)
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
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: invoice.location == .processing)
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
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: false)
    }

    func persistPreviewRotation(for artifactID: PhysicalArtifact.ID, quarterTurns: Int) async -> PreviewRotationSaveResult? {
        guard let invoice = invoices.first(where: { $0.id == artifactID }) else {
            return nil
        }

        return await persistPreviewRotation(
            for: PreviewCommitRequest(invoice: invoice, quarterTurns: quarterTurns)
        )
    }

    func persistPreviewRotation(for request: PreviewCommitRequest) async -> PreviewRotationSaveResult? {
        let rotation = normalizePreviewRotation(request.quarterTurns)
        guard rotation != 0,
              let invoice = resolvedInvoice(for: request) else {
            return nil
        }

        let handle = invoice.handle

        guard accessCoordinator.fileExists(for: handle) else {
            return nil
        }

        do {
            try await accessCoordinator.rotate(handle: handle, quarterTurns: rotation)

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
            duplicateTokensByHash: computationCache.duplicateTokensByHash,
            duplicateFirstPageTokensByHash: computationCache.firstPageDuplicateTokensByHash
        )
        invoices = librarySnapshot.artifacts
        documents = librarySnapshot.documents
    }

    private func syncSelectionForVisibleInvoices() {
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

        guard let first = visible.first?.id else { return }
        setSelection(ids: [first], primary: first)
    }

    private func setSelection(ids: Set<PhysicalArtifact.ID>, primary: PhysicalArtifact.ID?) {
        isSynchronizingSelection = true
        selectedArtifactIDs = ids
        selectedArtifactID = primary
        isSynchronizingSelection = false
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
            return result.updatedArtifactID
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
            setDocumentMetadata(candidateMetadata, for: document.id, renameProcessingFiles: false)
        }
    }

    private func setDocumentMetadata(
        _ metadata: DocumentMetadata,
        for documentID: Document.ID,
        renameProcessingFiles: Bool
    ) {
        guard let document = librarySnapshot.documentsByID[documentID] else { return }
        applyDocumentMetadata(metadata, toArtifactIDs: document.artifactIDs, renameProcessingFiles: renameProcessingFiles)
    }

    private func applyDocumentMetadata(
        _ metadata: DocumentMetadata,
        toArtifactIDs artifactIDs: Set<PhysicalArtifact.ID>,
        renameProcessingFiles: Bool
    ) {
        let artifacts = invoices.filter { artifactIDs.contains($0.id) }

        var requiresPersist = false

        for artifact in artifacts {
            let existingWorkflow = workflowByID[artifact.id]
            let nextWorkflow = StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: metadata.isEmpty ? nil : .document
            )

            if renameProcessingFiles && artifact.location == .processing {
                _ = applyWorkflow(nextWorkflow, to: artifact.id)
            } else {
                workflowByID[artifact.id] = nextWorkflow
                requiresPersist = true
            }
        }

        if requiresPersist {
            persistWorkflow()
        }

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
        applyDocumentMetadata(metadata, toArtifactIDs: context.artifactIDs, renameProcessingFiles: false)
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
}
