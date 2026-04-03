import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

enum InvoiceTextSource: String, Codable, Sendable {
    case pdfText
    case ocr
}

struct InvoiceTextRecord: Codable, Equatable, Sendable {
    let text: String
    let source: InvoiceTextSource
    let extractedAt: Date
    let schemaVersion: Int

    init(text: String, source: InvoiceTextSource, extractedAt: Date = .now, schemaVersion: Int = 1) {
        self.text = text
        self.source = source
        self.extractedAt = extractedAt
        self.schemaVersion = schemaVersion
    }
}

protocol DocumentTextExtracting: Sendable {
    func extractText(from fileURL: URL, fileType: InvoiceFileType) async throws -> InvoiceTextRecord?
}

struct DocumentTextExtractor: DocumentTextExtracting {
    typealias PDFTextLoader = @Sendable (URL) throws -> String?
    typealias OCRLoader = @Sendable (URL) async throws -> String?

    let extractEmbeddedPDFText: PDFTextLoader
    let recognizePDFText: OCRLoader
    let recognizeImageText: OCRLoader

    init(
        extractEmbeddedPDFText: @escaping PDFTextLoader = PDFEmbeddedTextLoader.loadText(from:),
        recognizePDFText: @escaping OCRLoader = VisionInvoiceOCR.loadTextFromPDF(from:),
        recognizeImageText: @escaping OCRLoader = VisionInvoiceOCR.loadTextFromImage(from:)
    ) {
        self.extractEmbeddedPDFText = extractEmbeddedPDFText
        self.recognizePDFText = recognizePDFText
        self.recognizeImageText = recognizeImageText
    }

    func extractText(from fileURL: URL, fileType: InvoiceFileType) async throws -> InvoiceTextRecord? {
        switch fileType {
        case .pdf:
            if let text = Self.normalizeText(try extractEmbeddedPDFText(fileURL)) {
                return InvoiceTextRecord(text: text, source: .pdfText)
            }

            if let text = Self.normalizeText(try await recognizePDFText(fileURL)) {
                return InvoiceTextRecord(text: text, source: .ocr)
            }

            return nil

        case .image, .jpeg, .heic:
            guard let text = Self.normalizeText(try await recognizeImageText(fileURL)) else {
                return nil
            }
            return InvoiceTextRecord(text: text, source: .ocr)
        }
    }

    static func normalizeText(_ text: String?) -> String? {
        guard let text else { return nil }

        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false)

        var cleanedLines: [String] = []
        var previousLineWasBlank = false

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                guard !previousLineWasBlank else { continue }
                cleanedLines.append("")
                previousLineWasBlank = true
            } else {
                cleanedLines.append(line)
                previousLineWasBlank = false
            }
        }

        let cleanedText = cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedText.isEmpty ? nil : cleanedText
    }
}

private enum DocumentTextExtractionError: LocalizedError {
    case unreadablePDF
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "Unable to open PDF for text extraction."
        case .unreadableImage:
            return "Unable to open image for OCR."
        }
    }
}

private enum PDFEmbeddedTextLoader {
    static func loadText(from fileURL: URL) throws -> String? {
        guard let document = PDFDocument(url: fileURL) else {
            throw DocumentTextExtractionError.unreadablePDF
        }

        return document.string
    }
}

private enum VisionInvoiceOCR {
    static func loadTextFromPDF(from fileURL: URL) async throws -> String? {
        let pageImages = try await Task.detached(priority: .utility) {
            try renderPDFPages(from: fileURL)
        }.value

        return try await recognizeText(in: pageImages)
    }

    static func loadTextFromImage(from fileURL: URL) async throws -> String? {
        let image = try await Task.detached(priority: .utility) {
            try loadImage(from: fileURL)
        }.value

        return try await recognizeText(in: [image])
    }

    private static func recognizeText(in images: [CGImage]) async throws -> String? {
        guard !images.isEmpty else { return nil }

        return try await Task.detached(priority: .utility) {
            var chunks: [String] = []

            for image in images {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: image)
                try handler.perform([request])

                let recognizedText = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !recognizedText.isEmpty {
                    chunks.append(recognizedText)
                }
            }

            let combined = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return combined.isEmpty ? nil : combined
        }.value
    }

    private static func renderPDFPages(from fileURL: URL) throws -> [CGImage] {
        guard let document = PDFDocument(url: fileURL) else {
            throw DocumentTextExtractionError.unreadablePDF
        }

        var images: [CGImage] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let bounds = page.bounds(for: .mediaBox)
            let maxDimension = max(bounds.width, bounds.height)
            let scale = maxDimension > 0 ? min(2000 / maxDimension, 3) : 1
            let size = NSSize(
                width: max(bounds.width * scale, 1),
                height: max(bounds.height * scale, 1)
            )
            let image = page.thumbnail(of: size, for: .mediaBox)

            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                images.append(cgImage)
            }
        }

        return images
    }

    private static func loadImage(from fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DocumentTextExtractionError.unreadableImage
        }

        return image
    }
}
