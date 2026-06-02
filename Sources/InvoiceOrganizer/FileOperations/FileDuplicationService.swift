import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Creates a near-identical copy of a document that carries a unique, invisible metadata
/// marker so the copy has a *different* content hash than the original. This lets a single
/// captured file (e.g. a photo containing two receipts) be split into independent documents
/// that can each be processed and named separately, without the deduplicator treating them
/// as identical files.
///
/// The pixel/page content is preserved losslessly — only metadata is altered.
enum FileDuplicationService {
    static func duplicate(source: URL, to destination: URL, fileType: InvoiceFileType) throws {
        switch fileType {
        case .pdf:
            try duplicatePDF(source: source, to: destination)
        case .image, .jpeg, .heic:
            try duplicateImage(source: source, to: destination)
        }
    }

    // MARK: - PDF

    private static func duplicatePDF(source: URL, to destination: URL) throws {
        guard let document = PDFDocument(url: source) else {
            throw DuplicationError.unreadableFile(source)
        }

        var attributes = document.documentAttributes ?? [:]
        // A unique keyword guarantees the serialized bytes differ from the original.
        attributes[PDFDocumentAttribute.keywordsAttribute] = [uniqueMarker()]
        document.documentAttributes = attributes

        let temporaryURL = temporaryURL(for: destination)
        guard document.write(to: temporaryURL) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DuplicationError.writeFailed
        }
        try moveIntoPlace(from: temporaryURL, to: destination)
    }

    // MARK: - Images

    private static func duplicateImage(source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(imageSource) else {
            throw DuplicationError.unreadableFile(source)
        }

        let frameCount = max(CGImageSourceGetCount(imageSource), 1)
        let temporaryURL = temporaryURL(for: destination)

        guard let destinationRef = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            sourceType,
            frameCount,
            nil
        ) else {
            throw DuplicationError.writeFailed
        }

        // Override a benign metadata field with a unique value across the common
        // container formats. `AddImageFromSource` copies the encoded image as-is, so
        // no re-compression occurs.
        let marker = uniqueMarker()
        let markerProperties: CFDictionary = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: marker],
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGComment: marker],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: marker]
        ] as CFDictionary

        CGImageDestinationAddImageFromSource(destinationRef, imageSource, 0, markerProperties)
        if frameCount > 1 {
            for index in 1..<frameCount {
                CGImageDestinationAddImageFromSource(destinationRef, imageSource, index, nil)
            }
        }

        guard CGImageDestinationFinalize(destinationRef) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DuplicationError.writeFailed
        }
        try moveIntoPlace(from: temporaryURL, to: destination)
    }

    // MARK: - Helpers

    private static func uniqueMarker() -> String {
        "invoice-organizer-split:\(UUID().uuidString)"
    }

    private static func temporaryURL(for destination: URL) -> URL {
        let fileManager = FileManager.default
        let replacementDirectory = (try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )) ?? fileManager.temporaryDirectory

        let pathExtension = destination.pathExtension
        let base = replacementDirectory.appendingPathComponent(UUID().uuidString)
        return pathExtension.isEmpty ? base : base.appendingPathExtension(pathExtension)
    }

    private static func moveIntoPlace(from temporaryURL: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DuplicationError.writeFailed
        }
    }

    enum DuplicationError: LocalizedError {
        case unreadableFile(URL)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let fileURL):
                return "Could not read \(fileURL.lastPathComponent) to duplicate it."
            case .writeFailed:
                return "The duplicate copy could not be saved."
            }
        }
    }
}
