import Foundation
import PDFKit

/// Rewrites a PDF on disk with its pages in a new order.
///
/// `order` is a permutation of `0..<pageCount`, where `order[newIndex]` is the
/// original page index that should appear at `newIndex` in the rewritten file.
enum InvoiceFilePageReorder {
    static func reorderPages(at fileURL: URL, order: [Int]) throws {
        guard let document = PDFDocument(url: fileURL) else {
            throw ReorderError.unreadableFile
        }

        let pageCount = document.pageCount
        guard order.count == pageCount, Set(order) == Set(0..<pageCount) else {
            throw ReorderError.invalidOrder
        }

        guard order != Array(0..<pageCount) else {
            return
        }

        let originalPages: [PDFPage] = (0..<pageCount).compactMap { document.page(at: $0)?.copy() as? PDFPage }
        guard originalPages.count == pageCount else {
            throw ReorderError.unreadableFile
        }

        let reorderedDocument = PDFDocument()
        for (newIndex, originalIndex) in order.enumerated() {
            reorderedDocument.insert(originalPages[originalIndex], at: newIndex)
        }

        let temporaryURL = temporaryReplacementURL(for: fileURL)
        guard reorderedDocument.write(to: temporaryURL) else {
            throw ReorderError.writeFailed
        }

        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ReorderError.writeFailed
        }
    }

    private static func temporaryReplacementURL(for fileURL: URL) -> URL {
        let fileManager = FileManager.default
        let replacementDirectory = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileURL,
            create: true
        )

        let baseDirectory = replacementDirectory ?? fileManager.temporaryDirectory
        let fileName = UUID().uuidString + (fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension)")
        return baseDirectory.appendingPathComponent(fileName)
    }

    enum ReorderError: LocalizedError {
        case unreadableFile
        case invalidOrder
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "The PDF pages could not be read for reordering."
            case .invalidOrder:
                return "The requested page order was invalid."
            case .writeFailed:
                return "The reordered PDF could not be saved."
            }
        }
    }
}
