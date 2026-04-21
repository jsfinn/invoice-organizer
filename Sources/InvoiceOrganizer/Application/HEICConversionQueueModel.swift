import Foundation
import OSLog

struct HEICConversionBatchOutcome: Sendable {
    let convertedCount: Int
    let failedCount: Int
}

struct HEICAutoCandidate: Sendable {
    let fileURL: URL
    let modifiedAt: Date
}

@MainActor
final class HEICConversionQueueModel: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InvoiceOrganizer",
        category: "HEICConversion"
    )

    @Published private(set) var queueDepth: Int = 0
    @Published private(set) var convertedFiles: [HEICConvertedFile] = []
    @Published private(set) var hasUnreadActivity: Bool = false

    private var pendingConversionURLs: Set<URL> = []
    private var autoConversionFailedURLs: Set<URL> = []
    private var lastAutoHandledModifiedAtByURL: [URL: Date] = [:]

    func markActivitySeen() {
        hasUnreadActivity = false
    }

    func enqueueManual(
        _ heicFiles: [URL],
        originalHandling: HEICOriginalFileHandling,
        archiveRoot: URL?,
        onFinished: @MainActor @escaping (HEICConversionBatchOutcome) -> Void = { _ in }
    ) {
        enqueue(
            heicFiles,
            isAutomatic: false,
            originalHandling: originalHandling,
            archiveRoot: archiveRoot,
            onFinished: onFinished
        )
    }

    func enqueueAutomaticallyDetected(
        _ candidates: [HEICAutoCandidate],
        originalHandling: HEICOriginalFileHandling,
        archiveRoot: URL?,
        onFinished: @MainActor @escaping (HEICConversionBatchOutcome) -> Void = { _ in }
    ) {
        let standardizedCandidates = candidates.map { candidate in
            HEICAutoCandidate(
                fileURL: candidate.fileURL.standardizedFileURL,
                modifiedAt: candidate.modifiedAt
            )
        }
        let detectedSet = Set(standardizedCandidates.map(\.fileURL))
        autoConversionFailedURLs = autoConversionFailedURLs.intersection(detectedSet)
        lastAutoHandledModifiedAtByURL = lastAutoHandledModifiedAtByURL.filter { detectedSet.contains($0.key) }
        let retryCandidates = standardizedCandidates.filter { candidate in
            guard !autoConversionFailedURLs.contains(candidate.fileURL) else { return false }
            guard let lastHandled = lastAutoHandledModifiedAtByURL[candidate.fileURL] else { return true }
            return candidate.modifiedAt > lastHandled
        }
        enqueue(
            retryCandidates.map(\.fileURL),
            isAutomatic: true,
            originalHandling: originalHandling,
            archiveRoot: archiveRoot,
            onFinished: { [retryCandidates] outcome in
                if outcome.convertedCount > 0 {
                    for candidate in retryCandidates {
                        self.lastAutoHandledModifiedAtByURL[candidate.fileURL] = candidate.modifiedAt
                    }
                }
                onFinished(outcome)
            }
        )
    }

    private func enqueue(
        _ heicFiles: [URL],
        isAutomatic: Bool,
        originalHandling: HEICOriginalFileHandling,
        archiveRoot: URL?,
        onFinished: @MainActor @escaping (HEICConversionBatchOutcome) -> Void
    ) {
        let pendingFiles = heicFiles
            .map(\.standardizedFileURL)
            .filter { pendingConversionURLs.insert($0).inserted }
        guard !pendingFiles.isEmpty else {
            onFinished(HEICConversionBatchOutcome(convertedCount: 0, failedCount: 0))
            return
        }

        queueDepth += pendingFiles.count

        Task { [pendingFiles] in
            var convertedFiles: [HEICConvertedFile] = []
            var failedCount = 0
            var failureMessages: [String] = []

            for fileURL in pendingFiles {
                let result = await Task.detached(priority: .utility) {
                    Result {
                        try HEICConversionService.convertReplacingOriginalFile(
                            at: fileURL,
                            originalHandling: originalHandling,
                            archiveRoot: archiveRoot
                        )
                    }
                }.value

                switch result {
                case .success(let convertedFile):
                    convertedFiles.append(convertedFile)
                    autoConversionFailedURLs.remove(fileURL)
                case .failure(let error):
                    failedCount += 1
                    failureMessages.append("\(fileURL.path): \(error.localizedDescription)")
                    if isAutomatic {
                        autoConversionFailedURLs.insert(fileURL)
                    }
                }

                pendingConversionURLs.remove(fileURL)
                queueDepth = max(0, queueDepth - 1)
            }

            if !convertedFiles.isEmpty {
                self.convertedFiles.insert(contentsOf: convertedFiles.reversed(), at: 0)
                if self.convertedFiles.count > 200 {
                    self.convertedFiles = Array(self.convertedFiles.prefix(200))
                }
                hasUnreadActivity = true
            }

            if !failureMessages.isEmpty {
                logFailures(failureMessages, automatic: isAutomatic)
            }

            onFinished(
                HEICConversionBatchOutcome(
                    convertedCount: convertedFiles.count,
                    failedCount: failedCount
                )
            )
        }
    }

    private func logFailures(_ failureMessages: [String], automatic: Bool) {
        guard !failureMessages.isEmpty else { return }
        let mode = automatic ? "automatic" : "manual"
        Self.logger.error("\(mode, privacy: .public) conversion failures: \(failureMessages.count)")
        for message in failureMessages {
            Self.logger.error("\(message, privacy: .public)")
        }
    }
}
