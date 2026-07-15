import Foundation

/// Copies externally supplied files (e.g. dragged from Finder/Desktop or Mail
/// attachments) into the inbox folder that backs the Unprocessed queue.
///
/// The filesystem watcher picks the copied files up on the next reconciliation,
/// so this service only owns the physical copy, supported-type filtering, and
/// collision-free naming.
enum InboxImportService {
    struct ImportResult: Sendable {
        var importedURLs: [URL]
        var skippedUnsupportedURLs: [URL]

        var didImportAnything: Bool { !importedURLs.isEmpty }
    }

    /// Copies `sourceURLs` into `inboxRoot`, skipping unsupported file types.
    /// Originals are left in place (a copy is made, never a move).
    static func importFiles(_ sourceURLs: [URL], into inboxRoot: URL) throws -> ImportResult {
        try FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)

        var importedURLs: [URL] = []
        var skippedUnsupportedURLs: [URL] = []

        for sourceURL in sourceURLs {
            guard InboxFileScanner.isSupportedFile(url: sourceURL) else {
                skippedUnsupportedURLs.append(sourceURL)
                continue
            }

            let destinationURL = uniqueDestinationURL(
                in: inboxRoot,
                preferredName: sourceURL.lastPathComponent
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            importedURLs.append(destinationURL)
        }

        return ImportResult(
            importedURLs: importedURLs,
            skippedUnsupportedURLs: skippedUnsupportedURLs
        )
    }

    private static func uniqueDestinationURL(in folder: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let preferredURL = folder.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let originalURL = URL(fileURLWithPath: preferredName)
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let fileExtension = originalURL.pathExtension

        for index in 2...1000 {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(baseName) \(index)"
            } else {
                candidateName = "\(baseName) \(index).\(fileExtension)"
            }

            let candidateURL = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return folder.appendingPathComponent(UUID().uuidString + "-" + preferredName)
    }
}
