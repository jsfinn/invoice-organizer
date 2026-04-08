import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var invoices: [InvoiceItem]
    @Published var queueScreenContext: QueueScreenContext
    @Published var folderSettings: FolderSettings
    @Published var llmSettings: LLMSettings
    @Published var settingsErrorMessage: String?
    @Published private(set) var llmPreflightStatus: LLMPreflightStatus
    @Published private(set) var documents: [InvoiceDocument] = []
    @Published private(set) var duplicateGroups: [InvoiceDuplicateGroup] = []
    @Published private(set) var extractedTextHashes: Set<String> = []
    @Published private(set) var structuredDataHashes: Set<String> = []
    @Published private(set) var textPendingHashes: Set<String> = []
    @Published private(set) var textFailedHashes: Set<String> = []
    @Published private(set) var structuredPendingHashes: Set<String> = []
    @Published private(set) var structuredFailedHashes: Set<String> = []
    @Published private(set) var ignoredInvoiceIDs: Set<InvoiceItem.ID>

    private let textStore: any InvoiceTextStoring
    private let textExtractionQueue: InvoiceTextExtractionQueue
    private let structuredDataStore: any InvoiceStructuredDataStoring
    private let structuredExtractionClient: any InvoiceStructuredExtractionClient
    private let structuredExtractionQueue: InvoiceStructuredExtractionQueue
    private var queueHandlerSetupTask: Task<Void, Never>?
    private var extractedTextByHash: [String: InvoiceTextRecord] = [:]
    private var structuredDataByHash: [String: InvoiceStructuredDataRecord] = [:]
    private var workflowByID: [String: StoredInvoiceWorkflow]
    private var rescannedDocumentContextsByID: [InvoiceDocument.ID: DocumentRescanContext] = [:]
    private var rescannedDocumentIDsByHash: [String: Set<InvoiceDocument.ID>] = [:]
    private var watcher: FileSystemWatcher?
    private var refreshTask: Task<Void, Never>?
    private var suppressWatcherRefreshUntil: Date?
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
        self.ignoredInvoiceIDs = Self.loadIgnoredInvoiceIDs()
        self.textStore = textStore
        self.structuredDataStore = structuredDataStore
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
        configureWatcher()
        if autoRefresh {
            refreshLibrary()
        }
    }

    var selectedInvoiceIDs: Set<InvoiceItem.ID> {
        get { activeQueueTabContext.selectedInvoiceIDs }
        set {
            guard newValue != selectedInvoiceIDs else { return }
            setSelectedInvoiceIDs(newValue)
        }
    }

    var selectedInvoiceID: InvoiceItem.ID? {
        get { activeQueueTabContext.selectedInvoiceID }
        set {
            guard newValue != selectedInvoiceID else { return }
            setSelectedInvoiceID(newValue)
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

    var selectedInvoice: InvoiceItem? {
        guard let selectedInvoiceID else { return nil }
        return invoices.first(where: { $0.id == selectedInvoiceID })
    }

    func document(for invoiceID: InvoiceItem.ID) -> InvoiceDocument? {
        documentByInvoiceID[invoiceID]
    }

    var visibleInvoices: [InvoiceItem] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return invoices
            .filter { invoice in
                showIgnoredInvoices || !ignoredInvoiceIDs.contains(invoice.id)
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
        invoices.filter { $0.location == .inbox && (showIgnoredInvoices || !ignoredInvoiceIDs.contains($0.id)) }.count
    }

    var inProgressCount: Int {
        invoices.filter { $0.location == .processing && (showIgnoredInvoices || !ignoredInvoiceIDs.contains($0.id)) }.count
    }

    var processedCount: Int {
        invoices.filter { $0.location == .processed && (showIgnoredInvoices || !ignoredInvoiceIDs.contains($0.id)) }.count
    }

    var hiddenIgnoredCountInVisibleQueue: Int {
        guard !showIgnoredInvoices else { return 0 }
        return invoices.filter { invoice in
            ignoredInvoiceIDs.contains(invoice.id) && queueTab(for: invoice.location) == selectedQueueTab
        }.count
    }

    var activeBrowserContext: InvoiceBrowserContext {
        activeQueueTabContext.browserContext
    }

    var duplicateBadgeTitlesByInvoiceID: [InvoiceItem.ID: String] {
        return Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let title = documentByInvoiceID[invoice.id]?.badgeTitle(for: invoice.id) else {
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

    var isWatchingFolders: Bool {
        watcher != nil
    }

    var llmStatusMessage: String {
        llmPreflightStatus.message
    }

    var extractedTextInvoiceIDs: Set<InvoiceItem.ID> {
        Set(
            invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      extractedTextHashes.contains(contentHash) else {
                    return nil
                }

                return invoice.id
            }
        )
    }

    var ocrStatesByInvoiceID: [InvoiceItem.ID: InvoiceOCRState] {
        Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      invoice.location == .inbox || invoice.location == .processing else {
                    return nil
                }

                if extractedTextHashes.contains(contentHash) {
                    return (invoice.id, .success)
                }

                if textFailedHashes.contains(contentHash) {
                    return (invoice.id, .failed)
                }

                return (invoice.id, .waiting)
            }
        )
    }

    var readStatesByInvoiceID: [InvoiceItem.ID: InvoiceReadState] {
        Dictionary(
            uniqueKeysWithValues: invoices.compactMap { invoice in
                guard let contentHash = invoice.contentHash,
                      invoice.location == .inbox || invoice.location == .processing else {
                    return nil
                }

                if let record = structuredDataByHash[contentHash] {
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

    func setSelectedInvoiceIDs(_ ids: Set<InvoiceItem.ID>) {
        guard ids != selectedInvoiceIDs else { return }
        updateActiveQueueTabContext { $0.selectedInvoiceIDs = ids }

        guard !isSynchronizingSelection else { return }
        setSelectedInvoiceID(visibleInvoices.first(where: { ids.contains($0.id) })?.id)
    }

    func setSelectedInvoiceID(_ id: InvoiceItem.ID?) {
        guard id != selectedInvoiceID else { return }
        updateActiveQueueTabContext { $0.selectedInvoiceID = id }
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

    func setActiveBrowserExpandedGroupIDs(_ expandedGroupIDs: Set<InvoiceItem.ID>) {
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

    func hasExtractedText(for invoice: InvoiceItem) async -> Bool {
        guard let contentHash = invoice.contentHash else { return false }
        return await textStore.hasCachedText(forContentHash: contentHash)
    }

    func hasStructuredData(for invoice: InvoiceItem) async -> Bool {
        guard let contentHash = invoice.contentHash else { return false }
        return await structuredDataStore.hasCachedData(forContentHash: contentHash)
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
        configureWatcher()
        refreshLibrary()
    }

    func clearFolder(for role: FolderRole) {
        folderSettings.setURL(nil, for: role)
        persistFolderSettings()
        configureWatcher()
        refreshLibrary()
    }

    func refreshLibrary() {
        scheduleRefresh(immediate: true)
    }

    func moveSelectedToInProgress() {
        let orderedSelectedIDs = visibleInvoices
            .map(\.id)
            .filter { selectedInvoiceIDs.contains($0) }
        moveInvoicesToInProgress(ids: orderedSelectedIDs)
    }

    func rescanInvoices(ids: Set<InvoiceItem.ID>) async {
        await queueHandlerSetupTask?.value
        let selectedInvoices = invoices.filter { ids.contains($0.id) }
        guard !selectedInvoices.isEmpty else { return }

        let selectedInvoicesByDocumentID = Dictionary(grouping: selectedInvoices, by: \.documentID)
        var invoicesToRescan: [InvoiceItem] = []
        var contentHashes: Set<String> = []

        for (documentID, documentInvoices) in selectedInvoicesByDocumentID {
            guard let document = documentByID[documentID] else { continue }
            let selectedMemberIDs = Set(documentInvoices.map(\.id))
            let documentMemberIDs = document.memberIDs
            let shouldClearDocumentMetadata = selectedMemberIDs == documentMemberIDs

            if shouldClearDocumentMetadata {
                clearDocumentMetadata(for: document.id)
                let rescannedMembers = invoices.filter { documentMemberIDs.contains($0.id) }
                let rescannedHashes = Set(rescannedMembers.compactMap(\.contentHash))

                invoicesToRescan.append(contentsOf: rescannedMembers)
                contentHashes.formUnion(rescannedHashes)

                if !rescannedHashes.isEmpty {
                    rescannedDocumentContextsByID[document.id] = DocumentRescanContext(
                        documentID: document.id,
                        memberIDs: documentMemberIDs,
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

        for contentHash in contentHashes {
            await textStore.removeCachedText(forContentHash: contentHash)
            await structuredDataStore.removeCachedData(forContentHash: contentHash)
        }

        extractedTextHashes.subtract(contentHashes)
        structuredDataHashes.subtract(contentHashes)
        textPendingHashes.subtract(contentHashes)
        textFailedHashes.subtract(contentHashes)
        structuredPendingHashes.subtract(contentHashes)
        structuredFailedHashes.subtract(contentHashes)
        contentHashes.forEach { extractedTextByHash.removeValue(forKey: $0) }
        contentHashes.forEach { structuredDataByHash.removeValue(forKey: $0) }
        applyDuplicateStateFromExtractedText()

        await textExtractionQueue.enqueue(
            invoices: Array(Dictionary(uniqueKeysWithValues: invoicesToRescan.map { ($0.id, $0) }).values),
            knownCachedHashes: extractedTextHashes.union(textFailedHashes),
            force: true
        )
    }

    func setIgnored(_ ignored: Bool, for ids: Set<InvoiceItem.ID>) {
        guard !ids.isEmpty else { return }

        if ignored {
            ignoredInvoiceIDs.formUnion(ids)
        } else {
            ignoredInvoiceIDs.subtract(ids)
        }

        persistIgnoredInvoiceIDs()
        syncSelectionForVisibleInvoices()
    }

    func isIgnored(_ invoiceID: InvoiceItem.ID) -> Bool {
        ignoredInvoiceIDs.contains(invoiceID)
    }

    func moveInvoicesToInProgress(ids: Set<InvoiceItem.ID>) {
        moveInvoicesToInProgress(
            ids: orderedInvoiceIDsForProcessingMove(from: ids)
        )
    }

    func moveInvoicesToInProgress(ids: [InvoiceItem.ID]) {
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
            var movedIDs: Set<InvoiceItem.ID> = []
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
                    let processingInvoice = InvoiceItem(
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

                let newID = InvoiceItem.stableID(for: finalURL)
                workflowByID[newID] = workflow
                remapIgnoredID(from: oldID, to: newID)
                movedIDs.insert(newID)
            }

            persistWorkflow()
            settingsErrorMessage = nil
            refreshLibrary()
            selectedInvoiceIDs = movedIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToUnprocessed(ids: Set<InvoiceItem.ID>) {
        guard !ids.isEmpty else { return }
        guard let inboxRoot = folderSettings.inboxURL else {
            settingsErrorMessage = "Choose an Inbox folder before moving invoices back to Unprocessed."
            return
        }

        let eligibleIDs = Set(invoices.filter { ids.contains($0.id) && $0.location == .processing }.map(\.id))
        guard !eligibleIDs.isEmpty else { return }

        do {
            var movedIDs: Set<InvoiceItem.ID> = []

            for invoice in invoices where eligibleIDs.contains(invoice.id) {
                let destinationURL = try InvoiceWorkspaceMover.moveToInbox(invoice, inboxRoot: inboxRoot)
                let oldID = invoice.id
                let newID = InvoiceItem.stableID(for: destinationURL)

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
            selectedInvoiceIDs = movedIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func moveInvoicesToProcessed(ids: Set<InvoiceItem.ID>) {
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
            var archivedIDs: Set<InvoiceItem.ID> = []

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

                let archivedID = InvoiceItem.stableID(for: destinationURL)
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
            selectedInvoiceIDs = archivedIDs
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func updateVendor(_ vendor: String, for invoiceID: InvoiceItem.ID) {
        guard let invoice = invoices.first(where: { $0.id == invoiceID }),
              invoice.location == .processing else {
            return
        }

        let trimmedVendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVendor = trimmedVendor.isEmpty ? nil : trimmedVendor
        guard let document = documentByInvoiceID[invoiceID],
              document.metadata.vendor != normalizedVendor else {
            return
        }

        var metadata = document.metadata
        metadata.vendor = normalizedVendor
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: true)
    }

    func updateInvoiceDate(_ invoiceDate: Date, for invoiceID: InvoiceItem.ID) {
        guard let invoice = invoices.first(where: { $0.id == invoiceID }),
              invoice.location == .processing else {
            return
        }

        guard let document = documentByInvoiceID[invoiceID] else {
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

    func updateInvoiceNumber(_ invoiceNumber: String, for invoiceID: InvoiceItem.ID) {
        guard let invoice = invoices.first(where: { $0.id == invoiceID }),
              invoice.location == .processing || invoice.location == .processed else {
            return
        }

        let normalizedInvoiceNumber = normalizedInvoiceNumber(from: invoiceNumber)
        guard let document = documentByInvoiceID[invoiceID],
              document.metadata.invoiceNumber != normalizedInvoiceNumber else {
            return
        }

        var metadata = document.metadata
        metadata.invoiceNumber = normalizedInvoiceNumber
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: invoice.location == .processing)
    }

    func updateDocumentType(_ documentType: InvoiceDocumentType?, for invoiceID: InvoiceItem.ID) {
        guard let invoice = invoices.first(where: { $0.id == invoiceID }),
              invoice.location == .processing || invoice.location == .processed else {
            return
        }

        guard let document = documentByInvoiceID[invoiceID],
              document.metadata.documentType != documentType else {
            return
        }

        var metadata = document.metadata
        metadata.documentType = documentType
        setDocumentMetadata(metadata, for: document.id, renameProcessingFiles: false)
    }

    func persistPreviewRotation(for invoiceID: InvoiceItem.ID, quarterTurns: Int) async -> PreviewRotationSaveResult? {
        guard let invoice = invoices.first(where: { $0.id == invoiceID }) else {
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
            suppressWatcherRefreshUntil = Date().addingTimeInterval(1.5)

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

    private func updateSelectedInvoice(_ transform: (inout InvoiceItem) throws -> Void) throws {
        guard let selectedInvoiceID,
              let index = invoices.firstIndex(where: { $0.id == selectedInvoiceID }) else {
            return
        }

        var updated = invoices[index]
        try transform(&updated)
        invoices[index] = updated
    }

    private func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
            }
            await self.reloadLibrary()
        }
    }

    private func reloadLibrary() async {
        await queueHandlerSetupTask?.value
        guard let inboxURL = folderSettings.inboxURL else {
            invoices = []
            documents = []
            duplicateGroups = []
            extractedTextHashes = []
            extractedTextByHash = [:]
            structuredDataHashes = []
            structuredDataByHash = [:]
            textPendingHashes = []
            textFailedHashes = []
            structuredPendingHashes = []
            structuredFailedHashes = []
            setSelection(ids: [], primary: nil)
            settingsErrorMessage = nil
            return
        }

        let processedURL = folderSettings.processedURL
        let processingURL = folderSettings.processingURL
        let duplicatesURL = folderSettings.duplicatesURL
        let workflowSnapshot = workflowByID

        do {
            let loadedInvoices = try await Task.detached(priority: .utility) {
                let inboxFiles = try InboxFileScanner.scanFiles(
                    in: inboxURL,
                    location: .inbox,
                    recursive: false,
                    excluding: [processingURL, processedURL, duplicatesURL].compactMap { $0 }
                )
                let processingFiles = try processingURL.map {
                    try InboxFileScanner.scanFiles(in: $0, location: .processing, recursive: false)
                } ?? []
                let processedFiles = try processedURL.map { try InboxFileScanner.scanFiles(in: $0, location: .processed) } ?? []

                let activeInvoices = (inboxFiles + processingFiles).map { file in
                    InboxFileScanner.makeActiveInvoice(
                        from: file,
                        workflow: workflowSnapshot[file.id],
                        duplicateInfo: nil
                    )
                }

                let processedInvoices = processedFiles.map { file in
                    InboxFileScanner.makeProcessedInvoice(from: file, workflow: workflowSnapshot[file.id])
                }

                return (activeInvoices + processedInvoices).sorted { $0.addedAt > $1.addedAt }
            }.value

            invoices = loadedInvoices
            pruneWorkflowState(using: loadedInvoices)
            pruneIgnoredState(using: loadedInvoices)
            syncSelectionForVisibleInvoices()
            settingsErrorMessage = nil
            let cachedTextRecords = await textStore.cachedRecords()
            extractedTextByHash = cachedTextRecords
            extractedTextHashes = Set(cachedTextRecords.keys)
            let cachedStructuredRecords = await structuredDataStore.cachedRecords()
            structuredDataByHash = cachedStructuredRecords
            structuredDataHashes = Set(cachedStructuredRecords.keys)
            applyDuplicateStateFromExtractedText()
            await textExtractionQueue.enqueue(invoices: loadedInvoices, knownCachedHashes: extractedTextHashes.union(textFailedHashes))
            if canAttemptStructuredExtraction(with: llmSettings) {
                await enqueueStructuredExtraction(for: loadedInvoices)
            }
        } catch {
            invoices = []
            documents = []
            duplicateGroups = []
            extractedTextHashes = []
            extractedTextByHash = [:]
            structuredDataHashes = []
            structuredDataByHash = [:]
            textPendingHashes = []
            textFailedHashes = []
            structuredPendingHashes = []
            structuredFailedHashes = []
            setSelection(ids: [], primary: nil)
            settingsErrorMessage = error.localizedDescription
        }
    }

    private func pruneWorkflowState(using loadedInvoices: [InvoiceItem]) {
        let activeWorkflowIDs = Set(loadedInvoices.map(\.id))
        let previousKeys = Set(workflowByID.keys)
        let staleKeys = previousKeys.subtracting(activeWorkflowIDs)

        guard !staleKeys.isEmpty else { return }
        staleKeys.forEach { workflowByID.removeValue(forKey: $0) }
        persistWorkflow()
    }

    private func pruneIgnoredState(using loadedInvoices: [InvoiceItem]) {
        let activeIDs = Set(loadedInvoices.map(\.id))
        let staleIDs = ignoredInvoiceIDs.subtracting(activeIDs)
        guard !staleIDs.isEmpty else { return }

        ignoredInvoiceIDs.subtract(staleIDs)
        persistIgnoredInvoiceIDs()
    }

    private func configureWatcher() {
        let watchPaths = [folderSettings.inboxURL?.path, folderSettings.processingURL?.path, folderSettings.processedURL?.path].compactMap { $0 }
        guard !watchPaths.isEmpty else {
            watcher = nil
            return
        }

        if let watcher {
            watcher.restart(paths: watchPaths)
        } else {
            watcher = FileSystemWatcher(paths: watchPaths) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let suppressWatcherRefreshUntil = self.suppressWatcherRefreshUntil,
                       suppressWatcherRefreshUntil > Date() {
                        return
                    }
                    self.suppressWatcherRefreshUntil = nil
                    self.scheduleRefresh()
                }
            }
        }
    }

    private func persistWorkflow() {
        InvoiceWorkflowStore.save(workflowByID)
    }

    private func orderedInvoiceIDsForProcessingMove(from ids: Set<InvoiceItem.ID>) -> [InvoiceItem.ID] {
        let visibleOrderedIDs = visibleInvoices
            .map(\.id)
            .filter { ids.contains($0) }
        let visibleOrderedSet = Set(visibleOrderedIDs)
        let remainingIDs = invoices
            .map(\.id)
            .filter { ids.contains($0) && !visibleOrderedSet.contains($0) }
        return visibleOrderedIDs + remainingIDs
    }

    private func processingMovePlan(for orderedIDs: [InvoiceItem.ID]) -> (processingIDs: [InvoiceItem.ID], duplicateIDs: Set<InvoiceItem.ID>) {
        let documentByMemberID = Dictionary(
            uniqueKeysWithValues: documents.flatMap { document in
                document.memberIDs.map { ($0, document) }
            }
        )

        var processingIDs: [InvoiceItem.ID] = []
        var duplicateIDs: Set<InvoiceItem.ID> = []
        var handledDocumentIDs: Set<String> = []

        for invoiceID in orderedIDs {
            guard let document = documentByMemberID[invoiceID], document.isDuplicate else {
                processingIDs.append(invoiceID)
                continue
            }

            if handledDocumentIDs.insert(document.id).inserted {
                processingIDs.append(invoiceID)
                duplicateIDs.formUnion(
                    document.members.compactMap { member in
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

    private var documentByID: [InvoiceDocument.ID: InvoiceDocument] {
        Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
    }

    private var documentByInvoiceID: [InvoiceItem.ID: InvoiceDocument] {
        Dictionary(
            uniqueKeysWithValues: documents.flatMap { document in
                document.memberIDs.map { ($0, document) }
            }
        )
    }

    private var duplicateGroupByInvoiceID: [InvoiceItem.ID: InvoiceDuplicateGroup] {
        let entries: [(InvoiceItem.ID, InvoiceDuplicateGroup)] = documents.flatMap { document -> [(InvoiceItem.ID, InvoiceDuplicateGroup)] in
            guard document.isDuplicate else { return [] }

            let group = InvoiceDuplicateGroup(
                members: document.members.map {
                    InvoiceDuplicateMember(
                        id: $0.id,
                        fileURL: $0.fileURL,
                        location: $0.location,
                        addedAt: $0.addedAt,
                        fileType: $0.fileType
                    )
                }
            )

            return group.members.map { ($0.id, group) }
        }

        return Dictionary(uniqueKeysWithValues: entries)
    }

    private func syncSelectionForVisibleInvoices() {
        let visible = visibleInvoices
        guard !visible.isEmpty else {
            setSelection(ids: [], primary: nil)
            return
        }

        let visibleIDs = Set(visible.map(\.id))
        let retainedSelection = selectedInvoiceIDs.intersection(visibleIDs)

        if let selectedInvoiceID, visibleIDs.contains(selectedInvoiceID) {
            let nextSelection = retainedSelection.isEmpty ? [selectedInvoiceID] : retainedSelection
            setSelection(ids: nextSelection, primary: selectedInvoiceID)
            return
        }

        if let primary = visible.first(where: { retainedSelection.contains($0.id) })?.id {
            setSelection(ids: retainedSelection, primary: primary)
            return
        }

        guard let first = visible.first?.id else { return }
        setSelection(ids: [first], primary: first)
    }

    private func setSelection(ids: Set<InvoiceItem.ID>, primary: InvoiceItem.ID?) {
        isSynchronizingSelection = true
        selectedInvoiceIDs = ids
        selectedInvoiceID = primary
        isSynchronizingSelection = false
    }

    private func migrateCachedArtifacts(from previousContentHash: String?, to updatedContentHash: String?) async {
        guard let previousContentHash,
              let updatedContentHash,
              previousContentHash != updatedContentHash else {
            return
        }

        if let cachedText = await textStore.cachedText(forContentHash: previousContentHash) {
            await textStore.save(cachedText, forContentHash: updatedContentHash)
            await textStore.removeCachedText(forContentHash: previousContentHash)
        }

        if let cachedStructuredData = await structuredDataStore.cachedData(forContentHash: previousContentHash) {
            await structuredDataStore.save(cachedStructuredData, forContentHash: updatedContentHash)
            await structuredDataStore.removeCachedData(forContentHash: previousContentHash)
        }

        remapHashState(from: previousContentHash, to: updatedContentHash)
    }

    private func remapHashState(from previousContentHash: String, to updatedContentHash: String) {
        if extractedTextHashes.remove(previousContentHash) != nil {
            extractedTextHashes.insert(updatedContentHash)
        }
        if let record = extractedTextByHash.removeValue(forKey: previousContentHash) {
            extractedTextByHash[updatedContentHash] = record
        }
        if structuredDataHashes.remove(previousContentHash) != nil {
            structuredDataHashes.insert(updatedContentHash)
        }
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
        if let record = structuredDataByHash.removeValue(forKey: previousContentHash) {
            structuredDataByHash[updatedContentHash] = record
        }
    }

    private func remapIgnoredID(from previousID: InvoiceItem.ID, to updatedID: InvoiceItem.ID) {
        guard previousID != updatedID, ignoredInvoiceIDs.remove(previousID) != nil else {
            return
        }

        ignoredInvoiceIDs.insert(updatedID)
        persistIgnoredInvoiceIDs()
    }

    private func resolvedInvoice(for request: PreviewCommitRequest) -> InvoiceItem? {
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
    private func applyWorkflow(_ workflow: StoredInvoiceWorkflow, to invoiceID: InvoiceItem.ID) -> InvoiceItem.ID? {
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

                targetInvoice = InvoiceItem(
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
            targetInvoice = InvoiceItem(
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

        if selectedInvoiceIDs.contains(invoiceID) || selectedInvoiceID == invoiceID {
            let remappedSelection = Set(selectedInvoiceIDs.map { $0 == invoiceID ? nextID : $0 })
            setSelection(ids: remappedSelection, primary: selectedInvoiceID == invoiceID ? nextID : selectedInvoiceID)
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
        defaults.set(Array(ignoredInvoiceIDs).sorted(), forKey: UserDefaultsKey.ignoredInvoiceIDs)
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

    private static func loadIgnoredInvoiceIDs() -> Set<InvoiceItem.ID> {
        let defaults = UserDefaults.standard
        let storedIDs = defaults.stringArray(forKey: UserDefaultsKey.ignoredInvoiceIDs) ?? []
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

    private func enqueueStructuredExtraction(for invoices: [InvoiceItem], force: Bool = false) async {
        let cachedRecords = await structuredDataStore.cachedRecords()
        structuredDataByHash = cachedRecords
        let cachedHashes = Set(cachedRecords.keys)
        structuredDataHashes = cachedHashes
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
        extractedTextHashes.insert(contentHash)
        if let record = await textStore.cachedText(forContentHash: contentHash) {
            extractedTextByHash[contentHash] = record
        }
        applyDuplicateStateFromExtractedText()
        guard llmPreflightStatus.isReady || canAttemptStructuredExtraction(with: llmSettings) else {
            return
        }

        let matchingInvoices = invoices.filter { $0.contentHash == contentHash }
        guard !matchingInvoices.isEmpty else { return }

        await enqueueStructuredExtraction(for: matchingInvoices, force: true)
    }

    private func applyDuplicateStateFromExtractedText() {
        let detectedGroups = InvoiceDuplicateDetector.extractedTextDuplicateGroups(
            for: invoices,
            textRecordsByContentHash: extractedTextByHash
        )
        documents = buildDocuments(from: invoices, duplicateGroups: detectedGroups)
        duplicateGroups = documents.compactMap { document in
            guard document.isDuplicate else { return nil }
            return InvoiceDuplicateGroup(
                members: document.members.map {
                    InvoiceDuplicateMember(
                        id: $0.id,
                        fileURL: $0.fileURL,
                        location: $0.location,
                        addedAt: $0.addedAt,
                        fileType: $0.fileType
                    )
                }
            )
        }

        for index in invoices.indices {
            let invoiceID = invoices[index].id
            let document = documentByInvoiceID[invoiceID]
            let duplicateGroup = duplicateGroupByInvoiceID[invoiceID]

            invoices[index].documentID = document?.id ?? invoices[index].id
            invoices[index].vendor = document?.metadata.vendor
            invoices[index].invoiceDate = document?.metadata.invoiceDate
            invoices[index].invoiceNumber = document?.metadata.invoiceNumber
            invoices[index].documentType = document?.metadata.documentType

            if let duplicateInfo = duplicateGroup?.duplicateInfo(for: invoiceID) {
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
        structuredDataHashes.insert(contentHash)
        structuredDataByHash[contentHash] = record
        handleRescannedDocumentContentHashCompleted(contentHash)
        applyStructuredDataIfNeeded(contentHash: contentHash, record: record)
    }

    private func applyStructuredDataIfNeeded(contentHash: String, record: InvoiceStructuredDataRecord) {
        let matchingInvoices = invoices.filter { $0.contentHash == contentHash }

        for invoice in matchingInvoices {
            guard let document = documentByInvoiceID[invoice.id] else { continue }
            let candidateMetadata: InvoiceDocumentMetadata

            if document.members.count == 1 {
                let metadata = document.metadata
                candidateMetadata = InvoiceDocumentMetadata(
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
                candidateMetadata = InvoiceDocumentMetadata(
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

    private func buildDocuments(from invoices: [InvoiceItem], duplicateGroups: [InvoiceDuplicateGroup]) -> [InvoiceDocument] {
        let invoiceByID = Dictionary(uniqueKeysWithValues: invoices.map { ($0.id, $0) })
        var documents: [InvoiceDocument] = []
        var groupedInvoiceIDs: Set<InvoiceItem.ID> = []

        for group in duplicateGroups {
            let members = group.members.compactMap { member -> InvoiceDocumentMember? in
                guard let invoice = invoiceByID[member.id] else { return nil }
                return makeDocumentMember(from: invoice)
            }
            guard members.count > 1 else { continue }

            groupedInvoiceIDs.formUnion(members.map(\.id))
            documents.append(
                InvoiceDocument(
                    members: members,
                    metadata: resolvedDocumentMetadata(for: members, invoiceByID: invoiceByID)
                )
            )
        }

        for invoice in invoices where !groupedInvoiceIDs.contains(invoice.id) {
            let member = makeDocumentMember(from: invoice)
            documents.append(
                InvoiceDocument(
                    members: [member],
                    metadata: resolvedDocumentMetadata(for: [member], invoiceByID: invoiceByID)
                )
            )
        }

        return documents.sorted { lhs, rhs in
            let lhsDate = lhs.members.map(\.addedAt).max() ?? .distantPast
            let rhsDate = rhs.members.map(\.addedAt).max() ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            return lhs.id < rhs.id
        }
    }

    private func makeDocumentMember(from invoice: InvoiceItem) -> InvoiceDocumentMember {
        InvoiceDocumentMember(
            id: invoice.id,
            fileURL: invoice.fileURL,
            location: invoice.location,
            addedAt: invoice.addedAt,
            fileType: invoice.fileType,
            contentHash: invoice.contentHash
        )
    }

    private func resolvedDocumentMetadata(
        for members: [InvoiceDocumentMember],
        invoiceByID: [InvoiceItem.ID: InvoiceItem]
    ) -> InvoiceDocumentMetadata {
        if members.count == 1, let member = members.first {
            return singletonDocumentMetadata(for: member, invoiceByID: invoiceByID)
        }

        let workflowMetadata = sharedDuplicateDocumentMetadata(for: members)
        guard workflowMetadata.isEmpty else {
            return workflowMetadata
        }

        return inferredStructuredDocumentMetadata(for: members) ?? .empty
    }

    private func singletonDocumentMetadata(
        for member: InvoiceDocumentMember,
        invoiceByID: [InvoiceItem.ID: InvoiceItem]
    ) -> InvoiceDocumentMetadata {
        if let workflow = workflowByID[member.id] {
            return InvoiceDocumentMetadata(workflow: workflow)
        }

        guard let invoice = invoiceByID[member.id] else {
            return .empty
        }

        return InvoiceDocumentMetadata(invoice: invoice)
    }

    private func sharedDuplicateDocumentMetadata(for members: [InvoiceDocumentMember]) -> InvoiceDocumentMetadata {
        let workflows = members.compactMap { workflowByID[$0.id] }
        guard workflows.count == members.count,
              workflows.allSatisfy({ $0.metadataScope == .document }) else {
            return .empty
        }

        let metadata = workflows.map(InvoiceDocumentMetadata.init(workflow:))
        guard let first = metadata.first,
              metadata.dropFirst().allSatisfy({ $0 == first }) else {
            return .empty
        }

        return first
    }

    private func setDocumentMetadata(
        _ metadata: InvoiceDocumentMetadata,
        for documentID: InvoiceDocument.ID,
        renameProcessingFiles: Bool
    ) {
        guard let document = documentByID[documentID] else { return }
        applyDocumentMetadata(metadata, toMemberIDs: document.memberIDs, renameProcessingFiles: renameProcessingFiles)
    }

    private func applyDocumentMetadata(
        _ metadata: InvoiceDocumentMetadata,
        toMemberIDs memberIDs: Set<InvoiceItem.ID>,
        renameProcessingFiles: Bool
    ) {
        let members = invoices.filter { memberIDs.contains($0.id) }

        var requiresPersist = false

        for member in members {
            let existingWorkflow = workflowByID[member.id]
            let nextWorkflow = StoredInvoiceWorkflow(
                vendor: metadata.vendor,
                invoiceDate: metadata.invoiceDate,
                invoiceNumber: metadata.invoiceNumber,
                documentType: metadata.documentType,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: metadata.isEmpty ? nil : .document
            )

            if renameProcessingFiles && member.location == .processing {
                _ = applyWorkflow(nextWorkflow, to: member.id)
            } else {
                workflowByID[member.id] = nextWorkflow
                requiresPersist = true
            }
        }

        if requiresPersist {
            persistWorkflow()
        }

        applyDuplicateStateFromExtractedText()
    }

    private func clearDocumentMetadata(for documentID: InvoiceDocument.ID) {
        guard let document = documentByID[documentID] else { return }

        for member in document.members {
            let existingWorkflow = workflowByID[member.id]
            workflowByID[member.id] = StoredInvoiceWorkflow(
                vendor: nil,
                invoiceDate: nil,
                invoiceNumber: nil,
                documentType: nil,
                isInProgress: existingWorkflow?.isInProgress ?? false,
                metadataScope: nil
            )
        }

        persistWorkflow()
        applyDuplicateStateFromExtractedText()
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
        let metadata = mergedDocumentMetadata(for: context.memberIDs)
        applyDocumentMetadata(metadata, toMemberIDs: context.memberIDs, renameProcessingFiles: false)
    }

    private func mergedDocumentMetadata(for memberIDs: Set<InvoiceItem.ID>) -> InvoiceDocumentMetadata {
        let records = invoices
            .filter { memberIDs.contains($0.id) }
            .compactMap { invoice -> InvoiceStructuredDataRecord? in
                guard let contentHash = invoice.contentHash else { return nil }
                return structuredDataByHash[contentHash]
            }

        return InvoiceDocumentMetadata(
            vendor: mergedStructuredValue(records.map(\.companyName)),
            invoiceDate: mergedStructuredValue(records.map(\.invoiceDate)),
            invoiceNumber: normalizedInvoiceNumber(from: mergedStructuredValue(records.map(\.invoiceNumber)) ?? ""),
            documentType: mergedStructuredValue(records.map(\.documentType))
        )
    }

    private func inferredStructuredDocumentMetadata(for document: InvoiceDocument) -> InvoiceDocumentMetadata? {
        inferredStructuredDocumentMetadata(for: document.members)
    }

    private func inferredStructuredDocumentMetadata(for members: [InvoiceDocumentMember]) -> InvoiceDocumentMetadata? {
        let contentHashes = members.compactMap(\.contentHash)
        guard contentHashes.count == members.count,
              contentHashes.allSatisfy({ structuredDataByHash[$0] != nil }) else {
            return nil
        }

        return mergedDocumentMetadata(for: Set(members.map(\.id)))
    }

    private func mergedStructuredValue<T: Hashable>(_ values: [T?]) -> T? {
        let uniqueValues = Set(values.compactMap { $0 })
        guard uniqueValues.count == 1 else { return nil }
        return uniqueValues.first
    }

    private func shouldRenameOnMoveToInProgress(invoice: InvoiceItem, workflow: StoredInvoiceWorkflow) -> Bool {
        guard let contentHash = invoice.contentHash,
              let structuredRecord = structuredDataByHash[contentHash],
              structuredRecord.isHighConfidence else {
            return false
        }

        let vendor = (workflow.vendor ?? invoice.vendor)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let invoiceDate = workflow.invoiceDate ?? invoice.invoiceDate

        return !(vendor?.isEmpty ?? true) && invoiceDate != nil
    }

    func reloadLibraryForTesting() async {
        await reloadLibrary()
    }

    func waitForBackgroundTextExtractionForTesting() async {
        await textExtractionQueue.waitForIdle()
        await structuredExtractionQueue.waitForIdle()
    }

}

private struct DocumentRescanContext {
    let documentID: InvoiceDocument.ID
    let memberIDs: Set<InvoiceItem.ID>
    var pendingContentHashes: Set<String>
}

private enum UserDefaultsKey {
    static let inboxPath = "settings.inboxPath"
    static let processedPath = "settings.processedPath"
    static let processingPath = "settings.processingPath"
    static let duplicatesPath = "settings.duplicatesPath"
    static let ignoredInvoiceIDs = "settings.ignoredInvoiceIDs"
    static let llmProvider = "settings.llmProvider"
    static let llmBaseURL = "settings.llmBaseURL"
    static let llmModelName = "settings.llmModelName"
    static let llmAPIKey = "settings.llmAPIKey"
    static let llmCustomInstructions = "settings.llmCustomInstructions"
}
