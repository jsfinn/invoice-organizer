import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum InvoiceFileRotator {
    static func rotateFile(at fileURL: URL, fileType: InvoiceFileType, quarterTurns: Int) throws {
        let normalizedQuarterTurns = normalizeQuarterTurns(quarterTurns)
        guard normalizedQuarterTurns != 0 else { return }

        switch fileType {
        case .pdf:
            try rotatePDF(at: fileURL, quarterTurns: normalizedQuarterTurns)
        case .image, .jpeg, .heic:
            try rotateImage(at: fileURL, quarterTurns: normalizedQuarterTurns)
        }
    }

    private static func rotatePDF(at fileURL: URL, quarterTurns: Int) throws {
        guard let document = PDFDocument(url: fileURL) else {
            throw RotationError.unreadableFile
        }

        let rotationDelta = -quarterTurns * 90
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            page.rotation = normalizePageRotation(page.rotation + rotationDelta)
        }

        let temporaryURL = temporaryReplacementURL(for: fileURL)
        guard document.write(to: temporaryURL) else {
            throw RotationError.writeFailed
        }

        try replaceItem(at: fileURL, with: temporaryURL)
    }

    private static func rotateImage(at fileURL: URL, quarterTurns: Int) throws {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RotationError.unreadableFile
        }

        let rotatedImage = try rotate(cgImage: cgImage, quarterTurns: quarterTurns)
        let destinationType = CGImageSourceGetType(source)
            ?? UTType(filenameExtension: fileURL.pathExtension)?.identifier as CFString?
            ?? UTType.png.identifier as CFString
        let temporaryURL = temporaryReplacementURL(for: fileURL)

        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, destinationType, 1, nil) else {
            throw RotationError.writeFailed
        }

        let properties: CFDictionary = [kCGImagePropertyOrientation: 1] as CFDictionary
        CGImageDestinationAddImage(destination, rotatedImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw RotationError.writeFailed
        }

        try replaceItem(at: fileURL, with: temporaryURL)
    }

    private static func rotate(cgImage: CGImage, quarterTurns: Int) throws -> CGImage {
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let destinationSize = quarterTurns.isMultiple(of: 2)
            ? sourceSize
            : CGSize(width: sourceSize.height, height: sourceSize.width)

        guard let context = CGContext(
            data: nil,
            width: Int(destinationSize.width),
            height: Int(destinationSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RotationError.writeFailed
        }

        switch quarterTurns {
        case 1:
            context.translateBy(x: destinationSize.width, y: 0)
            context.rotate(by: .pi / 2)
        case 2:
            context.translateBy(x: destinationSize.width, y: destinationSize.height)
            context.rotate(by: .pi)
        case 3:
            context.translateBy(x: 0, y: destinationSize.height)
            context.rotate(by: -.pi / 2)
        default:
            break
        }

        context.draw(cgImage, in: CGRect(origin: .zero, size: sourceSize))

        guard let rotatedImage = context.makeImage() else {
            throw RotationError.writeFailed
        }

        return rotatedImage
    }

    private static func replaceItem(at originalURL: URL, with temporaryURL: URL) throws {
        let fileManager = FileManager.default
        _ = try fileManager.replaceItemAt(originalURL, withItemAt: temporaryURL)
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

    private static func normalizeQuarterTurns(_ value: Int) -> Int {
        let normalized = value % 4
        return normalized >= 0 ? normalized : normalized + 4
    }

    private static func normalizePageRotation(_ value: Int) -> Int {
        let normalized = value % 360
        return normalized >= 0 ? normalized : normalized + 360
    }

    enum RotationError: LocalizedError {
        case unreadableFile
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "The selected file could not be rotated."
            case .writeFailed:
                return "The rotated file could not be saved."
            }
        }
    }
}
