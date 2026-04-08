import AppKit
import ImageIO
import UniformTypeIdentifiers

enum DragExportService {
    static func dragURL(for invoice: PhysicalArtifact) throws -> URL {
        if invoice.fileType == .heic {
            return try exportTemporaryJPEG(from: invoice.fileURL, originalFilename: invoice.name)
        }

        return invoice.fileURL
    }

    static func itemProvider(for invoice: PhysicalArtifact, internalInvoiceIDs: [String]? = nil) -> NSItemProvider {
        let provider: NSItemProvider
        if invoice.fileType == .heic {
            provider = heicItemProvider(for: invoice)
        } else {
            provider = NSItemProvider(object: invoice.fileURL as NSURL)
        }

        attachInternalInvoiceIDs(internalInvoiceIDs, to: provider)
        return provider
    }

    static func jpegExportBasename(for originalFilename: String) -> String {
        let originalURL = URL(fileURLWithPath: originalFilename)
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        return baseName.isEmpty ? "invoice" : baseName
    }

    static func jpegExportFilename(for originalFilename: String) -> String {
        "\(jpegExportBasename(for: originalFilename)).jpg"
    }

    private static func heicItemProvider(for invoice: PhysicalArtifact) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = jpegExportBasename(for: invoice.name)
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            do {
                let exportURL = try exportTemporaryJPEG(from: invoice.fileURL, originalFilename: invoice.name)
                completion(exportURL, true, nil)
            } catch {
                completion(nil, false, error)
            }

            return nil
        }
        return provider
    }

    private static func attachInternalInvoiceIDs(_ invoiceIDs: [String]?, to provider: NSItemProvider) {
        guard let invoiceIDs, !invoiceIDs.isEmpty, let payload = InvoiceInternalDrag.encode(invoiceIDs) else {
            return
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: InvoiceInternalDrag.invoiceIDsType.identifier,
            visibility: .all
        ) { completion in
            completion(payload, nil)
            return nil
        }
    }

    private static func exportTemporaryJPEG(from fileURL: URL, originalFilename: String) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw DragExportError.unreadableImage
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
            throw DragExportError.unreadableImage
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvoiceOrganizerDragExports", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let exportURL = tempDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(jpegExportFilename(for: originalFilename))")

        guard let destination = CGImageDestinationCreateWithURL(
            exportURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw DragExportError.unwritableJPEG
        }

        let destinationOptions: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, destinationOptions)

        guard CGImageDestinationFinalize(destination) else {
            throw DragExportError.unwritableJPEG
        }

        return exportURL
    }
}

private enum DragExportError: LocalizedError {
    case unreadableImage
    case unwritableJPEG

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The HEIC file could not be prepared for drag-and-drop."
        case .unwritableJPEG:
            return "The JPEG drag export could not be created."
        }
    }
}
