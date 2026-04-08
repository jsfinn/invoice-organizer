import Foundation

enum InvoiceWorkspaceMover {
    static func moveToProcessing(_ invoice: PhysicalArtifact, processingRoot: URL) throws -> URL {
        try move(invoice, to: processingRoot)
    }

    static func moveToDuplicates(_ invoice: PhysicalArtifact, duplicatesRoot: URL) throws -> URL {
        try move(invoice, to: duplicatesRoot)
    }

    static func moveToInbox(_ invoice: PhysicalArtifact, inboxRoot: URL) throws -> URL {
        try move(invoice, to: inboxRoot)
    }

    static func renameInProcessing(_ invoice: PhysicalArtifact, vendor: String?, invoiceDate: Date?, invoiceNumber: String?) throws -> URL {
        let folder = invoice.fileURL.deletingLastPathComponent()
        let preferredName = ArchivePathBuilder.processingFilename(
            vendor: vendor,
            invoiceDate: invoiceDate,
            invoiceNumber: invoiceNumber,
            originalFileURL: invoice.fileURL
        )

        let destinationURL = uniqueDestinationURL(
            in: folder,
            preferredName: preferredName,
            currentURL: invoice.fileURL
        )

        guard destinationURL != invoice.fileURL else {
            return invoice.fileURL
        }

        try FileManager.default.moveItem(at: invoice.fileURL, to: destinationURL)
        return destinationURL
    }

    private static func move(_ invoice: PhysicalArtifact, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destinationURL = uniqueDestinationURL(
            in: folder,
            preferredName: invoice.fileURL.lastPathComponent,
            currentURL: nil
        )

        try FileManager.default.moveItem(at: invoice.fileURL, to: destinationURL)
        return destinationURL
    }

    private static func uniqueDestinationURL(in folder: URL, preferredName: String, currentURL: URL?) -> URL {
        let preferredURL = folder.appendingPathComponent(preferredName)
        if preferredURL == currentURL {
            return preferredURL
        }
        guard !FileManager.default.fileExists(atPath: preferredURL.path) else {
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
                if candidateURL == currentURL || !FileManager.default.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
            }

            return folder.appendingPathComponent(UUID().uuidString + "-" + preferredName)
        }

        return preferredURL
    }
}
