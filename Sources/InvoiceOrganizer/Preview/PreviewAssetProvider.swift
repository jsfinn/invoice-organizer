import AppKit
import ImageIO
import PDFKit

@MainActor
protocol PreviewAssetProviding: AnyObject {
    func asset(
        for fileURL: URL,
        contentHash: String?,
        fileType: InvoiceFileType,
        forceReload: Bool
    ) async throws -> PreviewAsset

    func invalidateAsset(for fileURL: URL)
}

enum PreviewAsset {
    case pdf(PDFDocument)
    case image(NSImage)
}

private enum PreviewCachedAssetValue {
    case pdf(Data)
    case image(NSImage)

    func makeAsset() throws -> PreviewAsset {
        switch self {
        case .pdf(let data):
            guard let document = PDFDocument(data: data) else {
                throw PreviewAssetError.unreadablePDF
            }
            return .pdf(document)
        case .image(let image):
            return .image(image)
        }
    }
}

@MainActor
final class PreviewAssetProvider: PreviewAssetProviding {
    static let shared = PreviewAssetProvider()

    private struct CacheEntry {
        let contentHash: String?
        let value: PreviewCachedAssetValue
    }

    private var assetsByURL: [URL: CacheEntry] = [:]

    func asset(
        for fileURL: URL,
        contentHash: String?,
        fileType: InvoiceFileType,
        forceReload: Bool = false
    ) async throws -> PreviewAsset {
        if !forceReload,
           let cached = assetsByURL[fileURL],
           cached.contentHash == contentHash {
            return try cached.value.makeAsset()
        }

        let value = try await PreviewAssetLoader.loadValue(for: fileURL, fileType: fileType)
        assetsByURL[fileURL] = CacheEntry(contentHash: contentHash, value: value)
        return try value.makeAsset()
    }

    func asset(for invoice: InvoiceItem, forceReload: Bool = false) async throws -> PreviewAsset {
        try await asset(
            for: invoice.fileURL,
            contentHash: invoice.contentHash,
            fileType: invoice.fileType,
            forceReload: forceReload
        )
    }

    func invalidateAsset(for fileURL: URL) {
        assetsByURL.removeValue(forKey: fileURL)
    }
}

private enum PreviewAssetLoader {
    static func loadValue(for fileURL: URL, fileType: InvoiceFileType) async throws -> PreviewCachedAssetValue {
        switch fileType {
        case .pdf:
            return try await loadPDF(from: fileURL)
        case .image, .jpeg, .heic:
            return try await loadImage(from: fileURL)
        }
    }

    private static func loadPDF(from fileURL: URL) async throws -> PreviewCachedAssetValue {
        let box = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: fileURL)
            guard PDFDocument(data: data) != nil else {
                throw PreviewAssetError.unreadablePDF
            }
            return PreviewCacheValueBox(value: PreviewCachedAssetValue.pdf(data))
        }.value
        return box.value
    }

    private static func loadImage(from fileURL: URL) async throws -> PreviewCachedAssetValue {
        let box = try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                throw PreviewAssetError.unreadableImage
            }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 4096
            let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 4096
            let maxPixelSize = max(pixelWidth, pixelHeight)

            let options: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw PreviewAssetError.unreadableImage
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            image.cacheMode = .always
            return PreviewCacheValueBox(value: PreviewCachedAssetValue.image(image))
        }.value
        return box.value
    }
}

private final class PreviewCacheValueBox: @unchecked Sendable {
    let value: PreviewCachedAssetValue

    init(value: PreviewCachedAssetValue) {
        self.value = value
    }
}

private enum PreviewAssetError: LocalizedError {
    case unreadablePDF
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "The selected PDF could not be loaded for preview."
        case .unreadableImage:
            return "The selected image could not be loaded for preview."
        }
    }
}
