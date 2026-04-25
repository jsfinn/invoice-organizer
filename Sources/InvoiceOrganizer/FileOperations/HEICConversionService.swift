import Foundation
import ImageIO
import UniformTypeIdentifiers

struct HEICConvertedFile: Identifiable, Hashable, Sendable {
    let originalURL: URL
    let convertedURL: URL
    let convertedAt: Date

    var id: String {
        "\(originalURL.standardizedFileURL.path)|\(convertedURL.standardizedFileURL.path)|\(convertedAt.timeIntervalSince1970)"
    }
}

struct HEICConversionResult: Sendable {
    let convertedFiles: [HEICConvertedFile]
    let failedConversions: [URL]

    var convertedCount: Int {
        convertedFiles.count
    }
}

enum HEICConversionService {
    static func heicFiles(in folderURL: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        return try files.filter { fileURL in
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { return false }
            return fileURL.pathExtension.caseInsensitiveCompare("heic") == .orderedSame
        }
    }

    static func convertReplacingOriginalFiles(_ heicFileURLs: [URL]) -> HEICConversionResult {
        var convertedFiles: [HEICConvertedFile] = []
        var failedConversions: [URL] = []

        for fileURL in heicFileURLs {
            do {
                convertedFiles.append(try convertReplacingOriginalFile(at: fileURL))
            } catch {
                failedConversions.append(fileURL)
            }
        }

        return HEICConversionResult(
            convertedFiles: convertedFiles,
            failedConversions: failedConversions
        )
    }

    static func convertReplacingOriginalFile(
        at fileURL: URL,
        originalHandling: HEICOriginalFileHandling = .delete,
        archiveRoot: URL? = nil
    ) throws -> HEICConvertedFile {
        let destinationURL = uniqueDestinationURL(for: fileURL)

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw ConversionError.unreadableImage(fileURL)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 4096
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 4096
        let maxPixelSize = max(pixelWidth, pixelHeight)

        let decodeOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions) else {
            throw ConversionError.unreadableImage(fileURL)
        }

        let temporaryURL = temporaryJPEGURL(for: destinationURL)
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.unwritableJPEG(destinationURL)
        }

        let destinationOptions: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, destinationOptions)

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.unwritableJPEG(destinationURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        try handleOriginalHEIC(at: fileURL, handling: originalHandling, archiveRoot: archiveRoot)

        PhysicalArtifactIdentityStore.shared.updateURL(from: fileURL, to: destinationURL)
        PhysicalArtifactIdentityStore.shared.save()

        return HEICConvertedFile(
            originalURL: fileURL,
            convertedURL: destinationURL,
            convertedAt: .now
        )
    }

    private static func temporaryJPEGURL(for destinationURL: URL) -> URL {
        let fileManager = FileManager.default
        let replacementDirectory = (try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )) ?? fileManager.temporaryDirectory

        return replacementDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
    }

    private static func uniqueDestinationURL(for sourceURL: URL) -> URL {
        let fileManager = FileManager.default
        let baseFilename = sourceURL.lastPathComponent
        let parentDirectory = sourceURL.deletingLastPathComponent()

        var candidateURL = parentDirectory
            .appendingPathComponent(baseFilename)
            .appendingPathExtension("jpg")
        guard !fileManager.fileExists(atPath: candidateURL.path) else {
            var suffix = 2
            while true {
                candidateURL = parentDirectory
                    .appendingPathComponent("\(baseFilename) (\(suffix))")
                    .appendingPathExtension("jpg")
                if !fileManager.fileExists(atPath: candidateURL.path) {
                    break
                }
                suffix += 1
            }
            return candidateURL
        }

        return candidateURL
    }

    private static func handleOriginalHEIC(
        at fileURL: URL,
        handling: HEICOriginalFileHandling,
        archiveRoot: URL?
    ) throws {
        switch handling {
        case .delete:
            try FileManager.default.removeItem(at: fileURL)
        case .leaveInUnprocessed:
            return
        case .archive:
            guard let archiveRoot else {
                throw ConversionError.missingArchiveFolder
            }
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            let destination = uniqueArchiveURL(for: fileURL, in: archiveRoot)
            try FileManager.default.moveItem(at: fileURL, to: destination)
        }
    }

    private static func uniqueArchiveURL(for sourceURL: URL, in archiveRoot: URL) -> URL {
        let fileManager = FileManager.default
        let sourceFilename = sourceURL.lastPathComponent
        var candidate = archiveRoot.appendingPathComponent(sourceFilename)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var suffix = 2
        while true {
            let numberedName = ext.isEmpty ? "\(baseName) (\(suffix))" : "\(baseName) (\(suffix)).\(ext)"
            candidate = archiveRoot.appendingPathComponent(numberedName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private enum ConversionError: LocalizedError {
        case unreadableImage(URL)
        case unwritableJPEG(URL)
        case missingArchiveFolder

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let sourceURL):
                return "Could not read HEIC image at \(sourceURL.path)."
            case .unwritableJPEG(let destinationURL):
                return "Could not write JPEG to \(destinationURL.path)."
            case .missingArchiveFolder:
                return "Archive folder is not configured for HEIC originals."
            }
        }
    }
}
