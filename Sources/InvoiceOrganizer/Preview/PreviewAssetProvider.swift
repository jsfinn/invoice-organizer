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

@MainActor
final class PreviewAssetProvider: PreviewAssetProviding {
    static let shared = PreviewAssetProvider()

    private struct CacheEntry {
        let contentHash: String?
        let asset: PreviewAsset
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
            return cached.asset
        }

        let asset = try await PreviewAssetLoader.loadAsset(for: fileURL, fileType: fileType)
        assetsByURL[fileURL] = CacheEntry(contentHash: contentHash, asset: asset)
        return asset
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
    static func loadAsset(for fileURL: URL, fileType: InvoiceFileType) async throws -> PreviewAsset {
        switch fileType {
        case .pdf:
            return try await loadPDF(from: fileURL)
        case .image, .jpeg, .heic:
            return try await loadImage(from: fileURL)
        }
    }

    private static func loadPDF(from fileURL: URL) async throws -> PreviewAsset {
        let box = try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: fileURL) else {
                throw PreviewAssetError.unreadablePDF
            }
            return PreviewAssetBox(asset: .pdf(document))
        }.value
        return box.asset
    }

    private static func loadImage(from fileURL: URL) async throws -> PreviewAsset {
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
            return PreviewAssetBox(asset: .image(image))
        }.value
        return box.asset
    }
}

private final class PreviewAssetBox: @unchecked Sendable {
    let asset: PreviewAsset

    init(asset: PreviewAsset) {
        self.asset = asset
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
