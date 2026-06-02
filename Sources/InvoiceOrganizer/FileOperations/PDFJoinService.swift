import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A single source file to be merged into a joined PDF, in page order.
struct PDFJoinSource: Sendable {
    let fileURL: URL
    let fileType: InvoiceFileType
}

/// Merges multiple source files (PDFs and images) into a single multi-page PDF.
///
/// PDF sources contribute their pages in order; image sources (JPEG/HEIC/other)
/// are rasterized onto a page sized to fit within US Letter bounds while
/// preserving aspect ratio.
enum PDFJoinService {
    /// Maximum page bounds for image-backed pages (US Letter at 72 DPI).
    private static let maxImagePageSize = CGSize(width: 612, height: 792)

    static func join(sources: [PDFJoinSource], to destinationURL: URL) throws {
        guard sources.count >= 2 else {
            throw JoinError.notEnoughSources
        }

        let mergedDocument = PDFDocument()
        var pageIndex = 0

        for source in sources {
            switch source.fileType {
            case .pdf:
                guard let document = PDFDocument(url: source.fileURL) else {
                    throw JoinError.unreadableFile(source.fileURL)
                }
                for sourcePageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: sourcePageIndex)?.copy() as? PDFPage else { continue }
                    mergedDocument.insert(page, at: pageIndex)
                    pageIndex += 1
                }
            case .image, .jpeg, .heic:
                let page = try imagePage(for: source.fileURL)
                mergedDocument.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }

        guard pageIndex > 0 else {
            throw JoinError.noPages
        }

        let temporaryURL = temporaryPDFURL(for: destinationURL)
        guard mergedDocument.write(to: temporaryURL) else {
            throw JoinError.writeFailed
        }

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw JoinError.writeFailed
        }
    }

    private static func imagePage(for fileURL: URL) throws -> PDFPage {
        let cgImage = try loadCGImage(at: fileURL)
        let fittedSize = fittedPageSize(forPixelWidth: cgImage.width, pixelHeight: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: fittedSize)

        guard let page = PDFPage(image: image) else {
            throw JoinError.unreadableFile(fileURL)
        }

        return page
    }

    /// Loads a fully-decoded, orientation-corrected image at native resolution.
    private static func loadCGImage(at fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw JoinError.unreadableFile(fileURL)
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
            throw JoinError.unreadableFile(fileURL)
        }

        return cgImage
    }

    static func fittedPageSize(forPixelWidth pixelWidth: Int, pixelHeight: Int) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return maxImagePageSize
        }

        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let scale = min(maxImagePageSize.width / width, maxImagePageSize.height / height)

        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    private static func temporaryPDFURL(for destinationURL: URL) -> URL {
        let fileManager = FileManager.default
        let replacementDirectory = (try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )) ?? fileManager.temporaryDirectory

        return replacementDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
    }

    enum JoinError: LocalizedError {
        case notEnoughSources
        case unreadableFile(URL)
        case noPages
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .notEnoughSources:
                return "Select at least two files to join into a PDF."
            case .unreadableFile(let fileURL):
                return "Could not read \(fileURL.lastPathComponent) while joining."
            case .noPages:
                return "The selected files produced no pages to join."
            case .writeFailed:
                return "The joined PDF could not be saved."
            }
        }
    }
}
