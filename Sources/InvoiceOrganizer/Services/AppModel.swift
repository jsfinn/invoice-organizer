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
    @Published private(set) var ignoredArtifactIDs: Set<PhysicalArtifact.ID>

    private let computationCache: ArtifactComputationCache
    private let textStore: any InvoiceTextStoring
    private let textExtractionQueue: InvoiceTextExtractionQueue
    private let structuredDataStore: any InvoiceStructuredDataStoring
    private let structuredExtractionClient: any InvoiceStructuredExtractionClient
    private let structuredExtractionQueue: InvoiceStructuredExtractionQueue
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
    private var workflowByID: [String: StoredInvoiceWorkflow]
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
        autoRefresh: Bool = true
    ) {
        let resolvedFolderSettings = folderSettings ?? Self.loadFolderSettings()
        let resolvedLLMSettings = llmSettings ?? Self.loadLLMSettings()

        self.queueScreenContext = QueueScreenContext()
        self.folderSettings = resolvedFolderSettings
        self.llmSettings = resolvedLLMSettings
        self.workflowByID = workflowByID ?? InvoiceWorkflowStore.load()
        self.ignoredArtifactIDs = Self.loadIgnoredInvoiceIDs()
        self.textStore = textStore
        self.structuredDataStore = structuredDataStore
        self.computationCache = ArtifactComputationCache(
            textStore: textStore,
            structuredDataStore: structuredDataStore
        )
        self.structuredExtractionClient = structuredExtractionClient
        self.llmPreflightStatus = Self.initialLLMPreflightStatus(for: resolvedLLMSettings)
        self.textExtractionQueue = InvoiceTextExtractionQueue(store: textStore, extractor: textExtractor)
        self.structuredExtractionQueue = InvoiceStructuredExtractionQueue(
            textStore: textStore,
            structuredDataStore: structuredDataStore,
            client: structuredExtractionClient
        )
        self.invoices = []
        self.queueHandlerSetupTask = Task { [textExtractionQueue = self.textExtractionQueue, structuredExtractionQueue = self.structuredExtractionQueue] in
            await textExtractionQueue.setOnRequestStarted { contentHash in
                self.textPendingHashes.insert(contentHash)
                self.textFailedHashes.remove(contentHash)
            }
            await textExtractionQueue.setOnRecordSaved { contentHash in
                await self.handleExtractedTextSaved(contentHash)
            }
            await textExtractionQueue.setOnRequestFailed { contentHash in
                self.textPendingHashes.remove(contentHash)
                self.textFailedHashes.insert(contentHash)
                self.handleRescannedDocumentContentHashCompleted(contentHash)
                self.applyDuplicateStateFromExtractedText()
            }
            await structuredExtractionQueue.setOnRequestStarted { contentHash in
                self.structuredPendingHashes.insert(contentHash)
                self.structuredFailedHashes.remove(contentHash)
            }
            await structuredExtractionQueue.setOnRecordSaved { contentHash, record in
                self.handleStructuredDataSaved(contentHash: contentHash, record: record)
            }
            await structuredExtractionQueue.setOnRequestFailed { contentHash, status in
                self.structuredPendingHashes.remove(contentHash)
                self.structuredFailedHashes.insert(contentHash)
                self.handleRescannedDocumentContentHashCompleted(contentHash)
                self.llmPreflightStatus = status
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

    var showIgnoredInvoices: Bool {
        get { queueScreenContext.showIgnoredInvoices }
        set {
            guard newValue != showIgnoredInvoices else { return }
            setShowIgnoredInvoices(newValue)
        }
    }

    var selectedArtifact: PhysicalArtifact? {
        guard let selectedArtifactID else { return nil }
        return invoices.first(where: { $0.id == selectedArtifactID })
    }

    func document(for artifactID: PhysicalArtifact.ID) -> Document? {
        documentByArtifactID[artifactID]
    }

    func duplicateSimilarities(for artifactID: PhysicalArtifact.ID, limit: Int = 5) -> [DuplicateSimilarity] {
        guard let artifact = invoices.first(where: { $0.id == artifactID }),
              let contentHash = artifact.contentHash,
              let artifactTokens = computationCache.duplicateTokens(forContentHash: contentHash) else {
            return []
        }

        return documents
            .filter { !$0.contains(artifactID: artifactID) }
            .compactMap { document in
                document.bestSimilarity(
                    to: artifactTokens,
                    tokensByArtifactID: duplicateTokenSetsByArtifactID,
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
                showIgnoredInvoices || !ignoredArtifactIDs.contains(invoice.id)
            }
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

                if let vendor = invoice.vendor, vendor.localizedCaseInsensitiveContains(trimmedSearchText) {
                    return true
                }

                return false
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var unprocessedCount: Int {
        invoices.filter { $0.location == .inbox && (showIgnoredInvoices || !ignoredArtifactIDs.contains($0.id)) }.count
    }

    var inProgressCount: Int {
        invoices.filter { $0.location == .processing && (showIgnoredInvoices || !ignoredArtifactIDs.contains($0.id)) }.count
    }

    var processedCount: Int {
        invoices.filter { $0.location == .processed && (showIgnoredInvoices || !ignoredArtifactIDs.contains($0.id)) }.count
    }

    var hiddenIgnoredCountInVisibleQueue: Int {
        guard !showIgnoredInvoices else { return 0 }
        return invoices.filter { invoice in
            ignoredArtifactIDs.contains(invoice.id) && queueTab(for: invoice.location) == selectedQueueTab
        }.count
    }

    var activeBrowserContext: InvoiceBrowserContext {
        activeQueueTabContext.browserContext
    }

    var duplicateBadgeTitlesByArtifactID: [PhysicalArtifact.ID: String] {
        return Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let title = documentByArtifactID[invoice.id]?.badgeTitle(forArtifactID: invoice.id) else {
                    return nil
                }

                return (invoice.id, title)
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

    var duplicatesFolderDisplayPath: String {
        folderSettings.duplicatesURL?.path ?? "Not selected"
    }

    func sourcePathDisplay(for invoice: PhysicalArtifact) -> String {
        invoice.fileURL.path
    }

    func processedFolderPreviewPath(for invoice: PhysicalArtifact) -> String? {
        switch invoice.location {
        case .inbox:
            return nil
        case .processing, .processed:
            let trimmedVendor = invoice.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedVendor.isEmpty else { return "" }
            return ArchivePathBuilder.destinationFolder(
                root: folderSettings.processedURL ?? URL(fileURLWithPath: "/Processed"),
                vendor: invoice.vendor
            ).path
        }
    }

    func dragExportURL(for invoice: PhysicalArtifact) throws -> URL {
        try DragExportService.dragURL(for: invoice)
    }

    func fileIcon(for invoice: PhysicalArtifact) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: invoice.fileURL.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
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

    func setShowIgnoredInvoices(_ showIgnored: Bool) {
        guard showIgnored != showIgnoredInvoices else { return }
        updateQueueScreenContext { $0.showIgnoredInvoices = showIgnored }
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

    func rescanInvoices(ids: Set<PhysicalArtifact.ID>) async {
        await queueHandlerSetupTask?.value
        let selectedArtifacts = invoices.filter { ids.contains($0.id) }
        guard !selectedArtifacts.isEmpty else { return }

        let selectedArtifactsByDocumentID = Dictionary(grouping: selectedArtifacts, by: \.documentID)
        var invoicesToRescan: [PhysicalArtifact] = []
        var contentHashes: Set<String> = []

        for (documentID, documentInvoices) in selectedArtifactsByDocumentID {
            guard let document = documentByID[documentID] else { continue }
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
        applyDuplicateStateFromExtractedText()

        await textExtractionQueue.enqueue(
            invoices: Array(Dictionary(uniqueKeysWithValues: invoicesToRescan.map { ($0.id, $0) }).values),
            knownCachedHashes: extractedTextHashes.union(textFailedHashes),
            force: true
        )
    }

    func setIgnored(_ ignored: Bool, for ids: Set<PhysicalArtifact.ID>) {
        guard !ids.isEmpty else { return }

        if ignored {
            ignoredArtifactIDs.formUnion(ids)
        } else {
            ignoredArtifactIDs.subtract(ids)
        }

        persistIgnoredInvoiceIDs()
        syncSelectionForVisibleInvoices()
    }

    func isIgnored(_ artifactID: PhysicalArtifact.ID) -> Bool {
        ignoredArtifactIDs.contains(artifactID)
    }

    func moveInvoicesToInProgress(ids: Set<PhysicalArtifact.ID>) {
        moveInvoicesToInProgress(
            ids: orderedInvoiceIDsForProcessingMove(from: ids)
        )
    }

    func moveInvoicesToInProgress(ids: [PhysicalArtifact.ID]) {
        let invoiceByID = Dictionary(uniqueKeysWithValues: invoices.map { ($0.id, $0) })
        let eligibleInvoices = ids.compactMap { invoiceByID[$0] }.filter(\.canMoveToInProgress)
        guard !eligibleInvoices.isEmpty else { return }
        guard let processingRoot = folderSettings.processingURL else {
            settingsErrorMessage = "Choose a Processing folder before moving invoices into In Progress."
            return
        }
        guard let duplicatesRoot = folderSettings.duplicatesURL else {
            settingsErrorMessage = "Choose a Duplicates folder before moving invoices into In Progress."
            return
        }

        do {
            var movedIDs: Set<PhysicalArtifact.ID> = []
            let movePlan = processingMovePlan(for: eligibleInvoices.map(\.id))

            for invoice in invoices where movePlan.duplicateIDs.contains(invoice.id) {
                _ = try InvoiceWorkspaceMover.moveToDuplicates(invoice, duplicatesRoot: duplicatesRoot)
            }

            for invoiceID in movePlan.processingIDs {
                guard let invoice = invoiceByID[invoiceID] else { continue }
                let destinationURL = try InvoiceWorkspaceMover.moveToProcessing(invoice, processingRoot: processingRoot)
                let oldID = invoice.id
                var finalURL = destinationURL

                var workflow = workflowByID.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                    vendor: invoice.vendor,
                    invoiceDate: invoice.invoiceDate,
                    invoiceNumber: invoice.invoiceNumber,
                    documentType: invoice.documentType,
                    isInProgress: false
                )
                workflow.isInProgress = false
                if shouldRenameOnMoveToInProgress(invoice: invoice, workflow: workflow) {
                    let processingInvoice = PhysicalArtifact(
                        name: finalURL.lastPathComponent,
                        fileURL: finalURL,
                        location: .processing,
                        vendor: workflow.vendor,
                        invoiceDate: workflow.invoiceDate,
                        invoiceNumber: workflow.invoiceNumber,
                        documentType: workflow.documentType,
                        addedAt: invoice.addedAt,
                        fileType: invoice.fileType,
                        status: .inProgress,
                        contentHash: invoice.contentHash,
                        duplicateOfPath: invoice.duplicateOfPath,
                        duplicateReason: invoice.duplicateReason
                    )
                    finalURL = try InvoiceWorkspaceMover.renameInProcessing(
                        processingInvoice,
                        vendor: workflow.vendor,
                        invoiceDate: workflow.invoiceDate,
                        invoiceNumber: workflow.invoiceNumber
                    )
                }

                let newID = PhysicalArtifact.stableID(for: finalURL)
                workflowByID[newID] = workflow
                remapIgnoredID(from: oldID, to: newID)
                movedIDs.insert(newID)
            }

            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
            selectedArtifactIDs = movedIDs
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

        let eligibleIDs = Set(invoices.filter { ids.contains($0.id) && $0.location == .processing }.map(\.id))
        guard !eligibleIDs.isEmpty else { return }

        do {
            var movedIDs: Set<PhysicalArtifact.ID> = []

            for invoice in invoices where eligibleIDs.contains(invoice.id) {
                let destinationURL = try InvoiceWorkspaceMover.moveToInbox(invoice, inboxRoot: inboxRoot)
                let oldID = invoice.id
                let newID = PhysicalArtifact.stableID(for: destinationURL)

                let workflow = workflowByID.removeValue(forKey: oldID) ?? StoredInvoiceWorkflow(
                    vendor: invoice.vendor,
                    invoiceDate: invoice.invoiceDate,
                    invoiceNumber: invoice.invoiceNumber,
                    documentType: invoice.documentType,
                    isInProgress: false
                )
                workflowByID[newID] = workflow
                remapIgnoredID(from: oldID, to: newID)
                movedIDs.insert(newID)
            }

            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
            selectedArtifactIDs = movedIDs
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

        let eligibleInvoices = invoices.filter { ids.contains($0.id) && $0.canMarkDone }
        guard !eligibleInvoices.isEmpty else { return }

        guard eligibleInvoices.allSatisfy({ !($0.vendor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) else {
            settingsErrorMessage = "Set a vendor before moving invoices to Processed."
            return
        }

        do {
            let processedAt = Date()
            var archivedIDs: Set<PhysicalArtifact.ID> = []

            for invoice in eligibleInvoices {
                let vendor = invoice.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let invoiceDate = invoice.invoiceDate ?? invoice.addedAt
                let destinationURL = try InvoiceArchiver.archive(
                    invoice,
                    processedRoot: processedRoot,
                    vendor: vendor,
                    invoiceDate: invoiceDate,
                    processedAt: processedAt
                )

                let archivedID = PhysicalArtifact.stableID(for: destinationURL)
                var workflow = workflowByID.removeValue(forKey: invoice.id) ?? StoredInvoiceWorkflow(
                    vendor: invoice.vendor,
                    invoiceDate: invoice.invoiceDate,
                    invoiceNumber: invoice.invoiceNumber,
                    documentType: invoice.documentType,
                    isInProgress: false
                )
                workflow.vendor = vendor
                workflow.invoiceDate = invoiceDate
                workflow.invoiceNumber = normalizedInvoiceNumber(from: invoice.invoiceNumber ?? "")
                workflow.documentType = invoice.documentType
                workflow.isInProgress = false
                workflowByID[archivedID] = workflow
                remapIgnoredID(from: invoice.id, to: archivedID)
                archivedIDs.insert(archivedID)
            }

            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
            selectedArtifactIDs = archivedIDs
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
        guard let document = documentByArtifactID[artifactID],
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

        guard let document = documentByArtifactID[artifactID] else {
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
        guard let document = documentByArtifactID[artifactID],
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

        guard let document = documentByArtifactID[artifactID],
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

        guard FileManager.default.fileExists(atPath: invoice.fileURL.path) else {
            return nil
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try InvoiceFileRotator.rotateFile(at: invoice.fileURL, fileType: invoice.fileType, quarterTurns: rotation)
            }.value

            let updatedContentHash = try? FileHasher.sha256(for: invoice.fileURL)
            await migrateCachedArtifacts(from: invoice.contentHash, to: updatedContentHash)
            fileSystemReconciler.suppressWatcherRefresh(for: 1.5)

            if let refreshedIndex = invoices.firstIndex(where: { $0.id == invoice.id }) {
                invoices[refreshedIndex].contentHash = updatedContentHash ?? invoices[refreshedIndex].contentHash
            }

            applyDuplicateStateFromExtractedText()
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
            await applyReconciledArtifacts(snapshot.artifacts)
        case .failure(let error):
            invoices = []
            documents = []
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

    private func applyReconciledArtifacts(_ loadedInvoices: [PhysicalArtifact]) async {
        invoices = loadedInvoices
        pruneWorkflowState(using: loadedInvoices)
        pruneIgnoredState(using: loadedInvoices)
        syncSelectionForVisibleInvoices()
        settingsErrorMessage = nil
        await computationCache.loadAll()
        syncComputationHashes()
        applyDuplicateStateFromExtractedText()
        await textExtractionQueue.enqueue(
            invoices: loadedInvoices,
            knownCachedHashes: extractedTextHashes.union(textFailedHashes)
        )
        if canAttemptStructuredExtraction(with: llmSettings) {
            await enqueueStructuredExtraction(for: loadedInvoices)
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

    private func pruneIgnoredState(using loadedInvoices: [PhysicalArtifact]) {
        let activeIDs = Set(loadedInvoices.map(\.id))
        let staleIDs = ignoredArtifactIDs.subtracting(activeIDs)
        guard !staleIDs.isEmpty else { return }

        ignoredArtifactIDs.subtract(staleIDs)
        persistIgnoredInvoiceIDs()
    }

    private func persistWorkflow() {
        InvoiceWorkflowStore.save(workflowByID)
    }

    private func orderedInvoiceIDsForProcessingMove(from ids: Set<PhysicalArtifact.ID>) -> [PhysicalArtifact.ID] {
        let visibleOrderedIDs = visibleArtifacts
            .map(\.id)
            .filter { ids.contains($0) }
        let visibleOrderedSet = Set(visibleOrderedIDs)
        let remainingIDs = invoices
            .map(\.id)
            .filter { ids.contains($0) && !visibleOrderedSet.contains($0) }
        return visibleOrderedIDs + remainingIDs
    }

    private func processingMovePlan(for orderedIDs: [PhysicalArtifact.ID]) -> (processingIDs: [PhysicalArtifact.ID], duplicateIDs: Set<PhysicalArtifact.ID>) {
        let documentByMemberID = Dictionary(
            uniqueKeysWithValues: documents.flatMap { document in
                document.artifactIDs.map { ($0, document) }
            }
        )

        var processingIDs: [PhysicalArtifact.ID] = []
        var duplicateIDs: Set<PhysicalArtifact.ID> = []
        var handledDocumentIDs: Set<String> = []

        for invoiceID in orderedIDs {
            guard let document = documentByMemberID[invoiceID], document.isDuplicate else {
                processingIDs.append(invoiceID)
                continue
            }

            if handledDocumentIDs.insert(document.id).inserted {
                processingIDs.append(invoiceID)
                duplicateIDs.formUnion(
                    document.artifacts.compactMap { member in
                        guard member.location != .processed,
                              member.id != invoiceID else {
                            return nil
                        }

                        return member.id
                    }
                )
            } else {
                duplicateIDs.insert(invoiceID)
            }
        }

        return (processingIDs, duplicateIDs)
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

    private var documentByID: [Document.ID: Document] {
        Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
    }

    private var documentByArtifactID: [PhysicalArtifact.ID: Document] {
        Dictionary(
            uniqueKeysWithValues: documents.flatMap { document in
                document.artifactIDs.map { ($0, document) }
            }
        )
    }

    private var duplicateTokenSetsByArtifactID: [PhysicalArtifact.ID: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      let tokens = computationCache.duplicateTokens(forContentHash: contentHash) else {
                    return nil
                }

                return (invoice.id, tokens)
            }
        )
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

    private func remapIgnoredID(from previousID: PhysicalArtifact.ID, to updatedID: PhysicalArtifact.ID) {
        guard previousID != updatedID, ignoredArtifactIDs.remove(previousID) != nil else {
            return
        }

        ignoredArtifactIDs.insert(updatedID)
        persistIgnoredInvoiceIDs()
    }

    private func resolvedInvoice(for request: PreviewCommitRequest) -> PhysicalArtifact? {
        if let byID = invoices.first(where: { $0.id == request.invoiceID }) {
            return byID
        }

        if let byURL = invoices.first(where: { $0.fileURL == request.fileURL }) {
            return byURL
        }

        if let contentHash = request.contentHash,
           let relocated = invoices.first(where: {
               $0.contentHash == contentHash &&
               $0.addedAt == request.addedAt &&
               $0.fileType == request.fileType
           }) {
            return relocated
        }

        return nil
    }

    @discardableResult
    private func applyWorkflow(_ workflow: StoredInvoiceWorkflow, to invoiceID: PhysicalArtifact.ID) -> PhysicalArtifact.ID? {
        guard let index = invoices.firstIndex(where: { $0.id == invoiceID }) else { return nil }

        let invoice = invoices[index]
        var targetInvoice = invoice
        var nextID = invoiceID

        if invoice.location == .processing {
            do {
                let renamedURL = try InvoiceWorkspaceMover.renameInProcessing(
                    invoice,
                    vendor: workflow.vendor,
                    invoiceDate: workflow.invoiceDate,
                    invoiceNumber: workflow.invoiceNumber
                )

                targetInvoice = PhysicalArtifact(
                    name: renamedURL.lastPathComponent,
                    fileURL: renamedURL,
                    location: invoice.location,
                    vendor: workflow.vendor,
                    invoiceDate: workflow.invoiceDate,
                    invoiceNumber: workflow.invoiceNumber,
                    documentType: workflow.documentType,
                    processedAt: invoice.processedAt,
                    addedAt: invoice.addedAt,
                    fileType: invoice.fileType,
                    status: invoice.status,
                    contentHash: invoice.contentHash,
                    duplicateOfPath: invoice.duplicateOfPath,
                    duplicateReason: invoice.duplicateReason
                )
                nextID = targetInvoice.id
            } catch {
                settingsErrorMessage = error.localizedDescription
                return nil
            }
        } else {
            targetInvoice = PhysicalArtifact(
                name: invoice.name,
                fileURL: invoice.fileURL,
                location: invoice.location,
                vendor: workflow.vendor,
                invoiceDate: workflow.invoiceDate,
                invoiceNumber: workflow.invoiceNumber,
                documentType: workflow.documentType,
                processedAt: invoice.processedAt,
                addedAt: invoice.addedAt,
                fileType: invoice.fileType,
                status: invoice.status,
                contentHash: invoice.contentHash,
                duplicateOfPath: invoice.duplicateOfPath,
                duplicateReason: invoice.duplicateReason
            )
        }

        workflowByID.removeValue(forKey: invoiceID)
        workflowByID[nextID] = workflow
        persistWorkflow()

        remapIgnoredID(from: invoiceID, to: nextID)

        invoices[index] = targetInvoice

        if selectedArtifactIDs.contains(invoiceID) || selectedArtifactID == invoiceID {
            let remappedSelection = Set(selectedArtifactIDs.map { $0 == invoiceID ? nextID : $0 })
            setSelection(ids: remappedSelection, primary: selectedArtifactID == invoiceID ? nextID : selectedArtifactID)
        }

        return nextID
    }

    private func normalizedInvoiceNumber(from invoiceNumber: String) -> String? {
        let trimmed = invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func queueTab(for location: InvoiceLocation) -> InvoiceQueueTab {
        switch location {
        case .inbox:
            return .unprocessed
        case .processing:
            return .inProgress
        case .processed:
            return .processed
        }
    }

    private func normalizePreviewRotation(_ value: Int) -> Int {
        let normalized = value % 4
        return normalized >= 0 ? normalized : normalized + 4
    }

    private func persistFolderSettings() {
        let defaults = UserDefaults.standard
        defaults.set(folderSettings.inboxURL?.path, forKey: UserDefaultsKey.inboxPath)
        defaults.set(folderSettings.processedURL?.path, forKey: UserDefaultsKey.processedPath)
        defaults.set(folderSettings.processingURL?.path, forKey: UserDefaultsKey.processingPath)
        defaults.set(folderSettings.duplicatesURL?.path, forKey: UserDefaultsKey.duplicatesPath)
    }

    private func persistIgnoredInvoiceIDs() {
        let defaults = UserDefaults.standard
        defaults.set(Array(ignoredArtifactIDs).sorted(), forKey: UserDefaultsKey.ignoredArtifactIDs)
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

    private static func loadIgnoredInvoiceIDs() -> Set<PhysicalArtifact.ID> {
        let defaults = UserDefaults.standard
        let storedIDs = defaults.stringArray(forKey: UserDefaultsKey.ignoredArtifactIDs) ?? []
        return Set(storedIDs)
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
        await structuredExtractionQueue.enqueue(
            invoices: invoices,
            knownStructuredHashes: cachedHashes.union(structuredFailedHashes),
            settings: llmSettings,
            force: force
        )
    }

    private func handleExtractedTextSaved(_ contentHash: String) async {
        textPendingHashes.remove(contentHash)
        textFailedHashes.remove(contentHash)
        await computationCache.syncExtractedText(forContentHash: contentHash)
        syncComputationHashes()
        applyDuplicateStateFromExtractedText()
        guard llmPreflightStatus.isReady || canAttemptStructuredExtraction(with: llmSettings) else {
            return
        }

        let matchingInvoices = invoices.filter { $0.contentHash == contentHash }
        guard !matchingInvoices.isEmpty else { return }

        await enqueueStructuredExtraction(for: matchingInvoices, force: true)
    }

    private func applyDuplicateStateFromExtractedText() {
        let duplicateClusters = DuplicateDetector.extractedTextDuplicateGroups(
            for: invoices,
            tokenSetsByContentHash: computationCache.duplicateTokensByHash
        )
        documents = buildDocuments(from: invoices, duplicateClusters: duplicateClusters)

        synchronizeInvoicesFromDerivedDocuments()
    }

    private func synchronizeInvoicesFromDerivedDocuments() {
        let documentLookup = documentByArtifactID

        for index in invoices.indices {
            let artifactID = invoices[index].id
            let document = documentLookup[artifactID]

            invoices[index].documentID = document?.id ?? invoices[index].id
            invoices[index].vendor = document?.metadata.vendor
            invoices[index].invoiceDate = document?.metadata.invoiceDate
            invoices[index].invoiceNumber = document?.metadata.invoiceNumber
            invoices[index].documentType = document?.metadata.documentType

            if let duplicateInfo = document?.duplicateInfo(forArtifactID: artifactID) {
                invoices[index].status = .blockedDuplicate
                invoices[index].duplicateOfPath = duplicateInfo.duplicateOfPath
                invoices[index].duplicateReason = duplicateInfo.reason
                continue
            }

            invoices[index].duplicateOfPath = nil
            invoices[index].duplicateReason = nil
            invoices[index].status = baseStatus(for: invoices[index].location)
        }
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
            guard let document = documentByArtifactID[invoice.id] else { continue }
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
                guard let mergedMetadata = inferredStructuredDocumentMetadata(for: document) else {
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

    private func buildDocuments(from artifacts: [PhysicalArtifact], duplicateClusters: [ArtifactDuplicateCluster]) -> [Document] {
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
                    metadata: resolvedDocumentMetadata(for: documentArtifacts, artifactsByID: artifactsByID)
                )
            )
        }

        for artifact in artifacts where !groupedArtifactIDs.contains(artifact.id) {
            let documentArtifact = makeDocumentArtifactReference(from: artifact)
            documents.append(
                Document(
                    artifacts: [documentArtifact],
                    metadata: resolvedDocumentMetadata(for: [documentArtifact], artifactsByID: artifactsByID)
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
            fileType: artifact.fileType,
            contentHash: artifact.contentHash
        )
    }

    private func resolvedDocumentMetadata(
        for artifacts: [DocumentArtifactReference],
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact]
    ) -> DocumentMetadata {
        if artifacts.count == 1, let artifact = artifacts.first {
            return singletonDocumentMetadata(for: artifact, artifactsByID: artifactsByID)
        }

        let workflowMetadata = sharedDuplicateDocumentMetadata(for: artifacts)
        guard workflowMetadata.isEmpty else {
            return workflowMetadata
        }

        return inferredStructuredDocumentMetadata(for: artifacts) ?? .empty
    }

    private func singletonDocumentMetadata(
        for artifact: DocumentArtifactReference,
        artifactsByID: [PhysicalArtifact.ID: PhysicalArtifact]
    ) -> DocumentMetadata {
        if let workflow = workflowByID[artifact.id] {
            return DocumentMetadata(workflow: workflow)
        }

        guard let resolvedArtifact = artifactsByID[artifact.id] else {
            return .empty
        }

        return DocumentMetadata(invoice: resolvedArtifact)
    }

    private func sharedDuplicateDocumentMetadata(for artifacts: [DocumentArtifactReference]) -> DocumentMetadata {
        let workflows = artifacts.compactMap { workflowByID[$0.id] }
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

    private func setDocumentMetadata(
        _ metadata: DocumentMetadata,
        for documentID: Document.ID,
        renameProcessingFiles: Bool
    ) {
        guard let document = documentByID[documentID] else { return }
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

        if renameProcessingFiles {
            applyDuplicateStateFromExtractedText()
        } else {
            updateDocumentMetadata(metadata, forArtifactIDs: artifactIDs)
            synchronizeInvoicesFromDerivedDocuments()
        }
    }

    private func clearDocumentMetadata(for documentID: Document.ID) {
        guard let document = documentByID[documentID] else { return }

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
        updateDocumentMetadata(.empty, forArtifactIDs: document.artifactIDs)
        synchronizeInvoicesFromDerivedDocuments()
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
        let records = invoices
            .filter { artifactIDs.contains($0.id) }
            .compactMap { invoice -> InvoiceStructuredDataRecord? in
                guard let contentHash = invoice.contentHash else { return nil }
                return computationCache.structuredRecord(forContentHash: contentHash)
            }

        return DocumentMetadata(
            vendor: mergedStructuredValue(records.map(\.companyName)),
            invoiceDate: mergedStructuredValue(records.map(\.invoiceDate)),
            invoiceNumber: normalizedInvoiceNumber(from: mergedStructuredValue(records.map(\.invoiceNumber)) ?? ""),
            documentType: mergedStructuredValue(records.map(\.documentType))
        )
    }

    private func inferredStructuredDocumentMetadata(for document: Document) -> DocumentMetadata? {
        inferredStructuredDocumentMetadata(for: document.artifacts)
    }

    private func inferredStructuredDocumentMetadata(for artifacts: [DocumentArtifactReference]) -> DocumentMetadata? {
        let contentHashes = artifacts.compactMap(\.contentHash)
        guard contentHashes.count == artifacts.count,
              contentHashes.allSatisfy({ computationCache.structuredRecord(forContentHash: $0) != nil }) else {
            return nil
        }

        return mergedDocumentMetadata(for: Set(artifacts.map(\.id)))
    }

    private func updateDocumentMetadata(_ metadata: DocumentMetadata, forArtifactIDs artifactIDs: Set<PhysicalArtifact.ID>) {
        guard let index = documents.firstIndex(where: { $0.artifactIDs == artifactIDs }) else {
            return
        }

        documents[index].metadata = metadata
    }

    private func mergedStructuredValue<T: Hashable>(_ values: [T?]) -> T? {
        let uniqueValues = Set(values.compactMap { $0 })
        guard uniqueValues.count == 1 else { return nil }
        return uniqueValues.first
    }

    private func shouldRenameOnMoveToInProgress(invoice: PhysicalArtifact, workflow: StoredInvoiceWorkflow) -> Bool {
        guard let contentHash = invoice.contentHash,
              let structuredRecord = computationCache.structuredRecord(forContentHash: contentHash),
              structuredRecord.isHighConfidence else {
            return false
        }

        let vendor = (workflow.vendor ?? invoice.vendor)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoiceDate = workflow.invoiceDate ?? invoice.invoiceDate

        return !(vendor?.isEmpty ?? true) && invoiceDate != nil
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
    static let ignoredArtifactIDs = "settings.ignoredArtifactIDs"
    static let llmProvider = "settings.llmProvider"
    static let llmBaseURL = "settings.llmBaseURL"
    static let llmModelName = "settings.llmModelName"
    static let llmAPIKey = "settings.llmAPIKey"
    static let llmCustomInstructions = "settings.llmCustomInstructions"
}
