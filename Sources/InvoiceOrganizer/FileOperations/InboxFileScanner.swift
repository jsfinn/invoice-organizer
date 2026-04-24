import Foundation
import UniformTypeIdentifiers

struct ScannedInvoiceFile: Hashable, Sendable {
    let id: String
    let name: String
    let fileURL: URL
    let location: InvoiceLocation
    let vendor: String?
    let invoiceDate: Date?
    let processedAt: Date?
    let addedAt: Date
    let modifiedAt: Date
    let fileType: InvoiceFileType
    let contentHash: String?

    init(
        id: String,
        name: String,
        fileURL: URL,
        location: InvoiceLocation,
        vendor: String?,
        invoiceDate: Date?,
        processedAt: Date?,
        addedAt: Date,
        modifiedAt: Date? = nil,
        fileType: InvoiceFileType,
        contentHash: String?
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.location = location
        self.vendor = vendor
        self.invoiceDate = invoiceDate
        self.processedAt = processedAt
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt ?? addedAt
        self.fileType = fileType
        self.contentHash = contentHash
    }
}

enum InboxFileScanner {
    static func scanFiles(
        in rootURL: URL,
        location: InvoiceLocation,
        recursive: Bool = true,
        excluding excludedRootURLs: [URL] = []
    ) throws -> [ScannedInvoiceFile] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]

        let normalizedExcludedRoots = excludedRootURLs.map(\.standardizedFileURL)
        let fileURLs = try listedFiles(
            in: rootURL,
            recursive: recursive,
            resourceKeys: resourceKeys,
            excluding: normalizedExcludedRoots
        )

        let scannedFiles: [ScannedInvoiceFile] = try fileURLs.compactMap { fileURL in
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { return nil }
            guard let fileType = fileType(for: fileURL) else { return nil }

            let fallbackDate = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate ?? .now
            let modifiedDate = values.contentModificationDate ?? fallbackDate
            let processedMetadata = location == .processed ? ArchivePathBuilder.processedMetadata(from: fileURL) : nil
            let contentHash = try? FileHasher.sha256(for: fileURL)

            return ScannedInvoiceFile(
                id: PhysicalArtifact.stableID(for: fileURL),
                name: fileURL.lastPathComponent,
                fileURL: fileURL,
                location: location,
                vendor: processedMetadata?.vendor,
                invoiceDate: processedMetadata?.invoiceDate,
                processedAt: processedMetadata?.processedAt,
                addedAt: processedMetadata?.processedAt ?? fallbackDate,
                modifiedAt: modifiedDate,
                fileType: fileType,
                contentHash: contentHash
            )
        }

        return scannedFiles.sorted { $0.addedAt > $1.addedAt }
    }

    static func makeActiveArtifact(from file: ScannedInvoiceFile, workflow: StoredInvoiceWorkflow?, duplicateInfo: DuplicateInfo?) -> PhysicalArtifact {
        let status: InvoiceStatus
        if duplicateInfo != nil {
            status = .blockedDuplicate
        } else if file.location == .processing {
            status = .inProgress
        } else {
            status = .unprocessed
        }

        return PhysicalArtifact(
            id: file.id,
            name: file.name,
            fileURL: file.fileURL,
            location: file.location,
            vendor: workflow?.vendor,
            invoiceDate: workflow?.invoiceDate,
            invoiceNumber: workflow?.invoiceNumber,
            documentType: workflow?.documentType,
            addedAt: file.addedAt,
            modifiedAt: file.modifiedAt,
            fileType: file.fileType,
            status: status,
            contentHash: file.contentHash,
            duplicateOfPath: duplicateInfo?.duplicateOfPath,
            duplicateReason: duplicateInfo?.reason
        )
    }

    static func makeProcessedArtifact(from file: ScannedInvoiceFile, workflow: StoredInvoiceWorkflow?) -> PhysicalArtifact {
        PhysicalArtifact(
            id: file.id,
            name: file.name,
            fileURL: file.fileURL,
            location: .processed,
            vendor: workflow?.vendor ?? file.vendor ?? file.fileURL.deletingLastPathComponent().lastPathComponent,
            invoiceDate: workflow?.invoiceDate ?? file.invoiceDate,
            invoiceNumber: workflow?.invoiceNumber,
            documentType: workflow?.documentType,
            processedAt: file.processedAt,
            addedAt: file.addedAt,
            modifiedAt: file.modifiedAt,
            fileType: file.fileType,
            status: .processed,
            contentHash: file.contentHash
        )
    }

    static func isSupportedFile(url: URL) -> Bool {
        fileType(for: url) != nil
    }

    private static func fileType(for fileURL: URL) -> InvoiceFileType? {
        let fileExtension = fileURL.pathExtension.lowercased()

        if fileExtension == "pdf" {
            return .pdf
        }

        if fileExtension == "jpg" || fileExtension == "jpeg" {
            return .jpeg
        }

        if fileExtension == "heic" {
            return .heic
        }

        guard let type = UTType(filenameExtension: fileExtension),
              type.conforms(to: .image) else {
            return nil
        }

        return .image
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path

        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func listedFiles(
        in rootURL: URL,
        recursive: Bool,
        resourceKeys: Set<URLResourceKey>,
        excluding excludedRootURLs: [URL]
    ) throws -> [URL] {
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            guard let enumerator else {
                return []
            }

            var fileURLs: [URL] = []
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                let normalizedFileURL = fileURL.standardizedFileURL

                if values.isDirectory == true,
                   excludedRootURLs.contains(where: { isSameOrDescendant(normalizedFileURL, of: $0) }) {
                    enumerator.skipDescendants()
                    continue
                }

                guard !excludedRootURLs.contains(where: { isSameOrDescendant(normalizedFileURL, of: $0) }) else {
                    continue
                }

                fileURLs.append(fileURL)
            }
            return fileURLs
        }

        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    }
}
