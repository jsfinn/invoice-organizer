import Foundation

struct FileSystemReconciliationSnapshot: Sendable {
    let artifacts: [PhysicalArtifact]
    let documentMetadataHintsByArtifactID: [PhysicalArtifact.ID: DocumentMetadata]
}

@MainActor
final class FileSystemReconciler {
    private let workflowProvider: @MainActor @Sendable () -> [String: StoredInvoiceWorkflow]
    private let onSnapshot: @MainActor @Sendable (Result<FileSystemReconciliationSnapshot, Error>) async -> Void
    private let periodicInterval: Duration?

    private var folderSettings: FolderSettings
    private var watcher: FileSystemWatcher?
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var suppressWatcherRefreshUntil: Date?

    init(
        folderSettings: FolderSettings,
        workflowProvider: @escaping @MainActor @Sendable () -> [String: StoredInvoiceWorkflow],
        onSnapshot: @escaping @MainActor @Sendable (Result<FileSystemReconciliationSnapshot, Error>) async -> Void,
        periodicInterval: Duration? = .seconds(30)
    ) {
        self.folderSettings = folderSettings
        self.workflowProvider = workflowProvider
        self.onSnapshot = onSnapshot
        self.periodicInterval = periodicInterval
    }

    var isWatchingFolders: Bool {
        watcher != nil
    }

    func updateConfiguration(folderSettings: FolderSettings, autoRefresh: Bool) {
        self.folderSettings = folderSettings
        configureWatcher()
        restartPeriodicReconciliationIfNeeded(autoRefresh: autoRefresh)
        if autoRefresh {
            scheduleRefresh(immediate: true)
        }
    }

    func refreshNow() {
        scheduleRefresh(immediate: true)
    }

    func reconcileNow() async {
        await emitSnapshot()
    }

    func suppressWatcherRefresh(for seconds: TimeInterval) {
        suppressWatcherRefreshUntil = Date().addingTimeInterval(seconds)
    }

    private func restartPeriodicReconciliationIfNeeded(autoRefresh: Bool) {
        periodicTask?.cancel()
        periodicTask = nil

        guard autoRefresh, let periodicInterval else {
            return
        }

        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: periodicInterval)
                guard !Task.isCancelled else { return }
                await self?.emitSnapshot()
            }
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
            }
            await self.emitSnapshot()
        }
    }

    private func configureWatcher() {
        let watchPaths = [
            folderSettings.inboxURL?.path,
            folderSettings.processingURL?.path,
            folderSettings.processedURL?.path,
            folderSettings.duplicatesURL?.path
        ]
        .compactMap { $0 }

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

    private func emitSnapshot() async {
        do {
            let snapshot = try await loadSnapshot(folderSettings: folderSettings, workflowSnapshot: workflowProvider())
            await onSnapshot(.success(snapshot))
        } catch {
            await onSnapshot(.failure(error))
        }
    }

    private func loadSnapshot(
        folderSettings: FolderSettings,
        workflowSnapshot: [String: StoredInvoiceWorkflow]
    ) async throws -> FileSystemReconciliationSnapshot {
        guard let inboxURL = folderSettings.inboxURL else {
            return FileSystemReconciliationSnapshot(artifacts: [], documentMetadataHintsByArtifactID: [:])
        }

        let processedURL = folderSettings.processedURL
        let processingURL = folderSettings.processingURL
        let duplicatesURL = folderSettings.duplicatesURL

        let snapshot = try await Task.detached(priority: .utility) {
            let inboxFiles = try InboxFileScanner.scanFiles(
                in: inboxURL,
                location: .inbox,
                recursive: false,
                excluding: [processingURL, processedURL, duplicatesURL].compactMap { $0 }
            )
            let processingFiles = try processingURL.map {
                try InboxFileScanner.scanFiles(in: $0, location: .processing, recursive: false)
            } ?? []
            let processedFiles = try processedURL.map {
                try InboxFileScanner.scanFiles(in: $0, location: .processed)
            } ?? []

            let activeArtifacts = (inboxFiles + processingFiles).map { file in
                InboxFileScanner.makeActiveArtifact(
                    from: file,
                    workflow: workflowSnapshot[file.id],
                    duplicateInfo: nil
                )
            }

            let processedArtifacts = processedFiles.map { file in
                InboxFileScanner.makeProcessedArtifact(from: file, workflow: workflowSnapshot[file.id])
            }

            // The archive nests files as <Letter>/<Vendor>/file, so the parent folder
            // names the vendor - but only for a file that actually sits in a vendor
            // folder. A file loose in the processed root would otherwise be credited
            // to a vendor named after the root itself.
            let processedRootPath = processedURL?.standardizedFileURL.path
            func vendorFolderName(for file: ScannedInvoiceFile) -> String? {
                let parent = file.fileURL.deletingLastPathComponent().standardizedFileURL
                guard parent.path != processedRootPath else { return nil }
                return parent.lastPathComponent
            }

            let metadataHints = Dictionary(
                uniqueKeysWithValues: processedFiles.map { file in
                    // Purely what the filename and folder say. The snapshot builder
                    // merges this under the workflow record, so mixing workflow
                    // values in here would just duplicate that logic.
                    return (
                        file.id,
                        DocumentMetadata(
                            vendor: file.vendor ?? vendorFolderName(for: file),
                            invoiceDate: file.invoiceDate,
                            invoiceNumber: file.invoiceNumber,
                            documentType: nil
                        )
                    )
                }
            )

            let allFiles = inboxFiles + processingFiles + processedFiles
            let identityStore = PhysicalArtifactIdentityStore.shared
            identityStore.prune(keepingPaths: Set(allFiles.map { $0.fileURL.standardizedFileURL.path }))
            identityStore.save()

            return FileSystemReconciliationSnapshot(
                artifacts: (activeArtifacts + processedArtifacts).sorted { $0.addedAt > $1.addedAt },
                documentMetadataHintsByArtifactID: metadataHints
            )
        }.value

        return snapshot
    }
}
