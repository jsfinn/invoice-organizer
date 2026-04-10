import Foundation

enum InvoiceArchiver {
    static func archive(
        _ invoice: PhysicalArtifact,
        processedRoot: URL,
        vendor: String?,
        invoiceDate: Date,
        invoiceNumber: String?
    ) throws -> URL {
        let destinationFolder = ArchivePathBuilder.destinationFolder(root: processedRoot, vendor: vendor)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let destinationURL = uniqueDestinationURL(
            in: destinationFolder,
            preferredName: ArchivePathBuilder.processedFilename(
                vendor: vendor,
                invoiceDate: invoiceDate,
                invoiceNumber: invoiceNumber,
                originalFileURL: invoice.fileURL
            )
        )

        try FileManager.default.moveItem(at: invoice.fileURL, to: destinationURL)
        return destinationURL
    }

    private static func uniqueDestinationURL(in folder: URL, preferredName: String) -> URL {
        let preferredURL = folder.appendingPathComponent(preferredName)
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
                if !FileManager.default.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
            }

            return folder.appendingPathComponent(UUID().uuidString + "-" + preferredName)
        }

        return preferredURL
    }
}
