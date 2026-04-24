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
    let firstPageText: String?
    let source: InvoiceTextSource
    let ocrConfidence: Double?
    let ocrOriginalText: String?
    let extractedAt: Date
    let schemaVersion: Int

    init(
        text: String,
        firstPageText: String? = nil,
        source: InvoiceTextSource,
        ocrConfidence: Double? = nil,
        ocrOriginalText: String? = nil,
        extractedAt: Date = .now,
        schemaVersion: Int = 4
    ) {
        self.text = text
        self.firstPageText = firstPageText
        self.source = source
        self.ocrConfidence = ocrConfidence
        self.ocrOriginalText = ocrOriginalText
        self.extractedAt = extractedAt
        self.schemaVersion = schemaVersion
    }
}

protocol DocumentTextExtracting: Sendable {
    func extractText(from fileURL: URL, fileType: InvoiceFileType) async throws -> InvoiceTextRecord?
}

struct DocumentTextExtractor: DocumentTextExtracting {
    typealias PDFTextLoader = @Sendable (URL) throws -> String?
    typealias OCRLoader = @Sendable (URL) async throws -> OCRTextResult?

    let extractEmbeddedPDFText: PDFTextLoader
    let extractFirstEmbeddedPDFText: PDFTextLoader
    let recognizePDFText: OCRLoader
    let recognizeImageText: OCRLoader

    init(
        extractEmbeddedPDFText: @escaping PDFTextLoader = PDFEmbeddedTextLoader.loadText(from:),
        extractFirstEmbeddedPDFText: @escaping PDFTextLoader = PDFEmbeddedTextLoader.loadFirstPageText(from:),
        recognizePDFText: @escaping OCRLoader = VisionInvoiceOCR.loadTextFromPDF(from:),
        recognizeImageText: @escaping OCRLoader = VisionInvoiceOCR.loadTextFromImage(from:)
    ) {
        self.extractEmbeddedPDFText = extractEmbeddedPDFText
        self.extractFirstEmbeddedPDFText = extractFirstEmbeddedPDFText
        self.recognizePDFText = recognizePDFText
        self.recognizeImageText = recognizeImageText
    }

    func extractText(from fileURL: URL, fileType: InvoiceFileType) async throws -> InvoiceTextRecord? {
        switch fileType {
        case .pdf:
            if let text = Self.normalizeText(try extractEmbeddedPDFText(fileURL)) {
                return InvoiceTextRecord(
                    text: text,
                    firstPageText: Self.normalizeText(try extractFirstEmbeddedPDFText(fileURL)) ?? text,
                    source: .pdfText
                )
            }

            if let ocrResult = try await recognizePDFText(fileURL),
               let text = Self.normalizeText(ocrResult.text) {
                return InvoiceTextRecord(
                    text: text,
                    firstPageText: Self.normalizeText(ocrResult.firstPageText) ?? text,
                    source: .ocr,
                    ocrConfidence: ocrResult.confidence,
                    ocrOriginalText: Self.normalizeText(ocrResult.originalText)
                )
            }

            return nil

        case .image, .jpeg, .heic:
            guard let ocrResult = try await recognizeImageText(fileURL),
                  let text = Self.normalizeText(ocrResult.text) else {
                return nil
            }
            return InvoiceTextRecord(
                text: text,
                firstPageText: Self.normalizeText(ocrResult.firstPageText) ?? text,
                source: .ocr,
                ocrConfidence: ocrResult.confidence,
                ocrOriginalText: Self.normalizeText(ocrResult.originalText)
            )
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

    static func loadFirstPageText(from fileURL: URL) throws -> String? {
        guard let document = PDFDocument(url: fileURL) else {
            throw DocumentTextExtractionError.unreadablePDF
        }

        return document.page(at: 0)?.string
    }
}

private enum VisionInvoiceOCR {
    static func loadTextFromPDF(from fileURL: URL) async throws -> OCRTextResult? {
        let pageImages = try await Task.detached(priority: .utility) {
            try renderPDFPages(from: fileURL)
        }.value

        return try await recognizeText(in: pageImages)
    }

    static func loadTextFromImage(from fileURL: URL) async throws -> OCRTextResult? {
        let image = try await Task.detached(priority: .utility) {
            try loadImage(from: fileURL)
        }.value

        return try await recognizeText(in: [image])
    }

    private static func recognizeText(in images: [CGImage]) async throws -> OCRTextResult? {
        guard !images.isEmpty else { return nil }

        return try await Task.detached(priority: .utility) {
            var reflowedChunks: [String] = []
            var originalChunks: [String] = []
            var firstPageReflowedText: String?
            var weightedConfidenceSum = 0.0
            var weightedConfidenceCount = 0

            for (index, image) in images.enumerated() {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: image)
                try handler.perform([request])

                let observations = (request.results ?? [])
                    .compactMap { observation -> OCRLineObservation? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }

                        let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { return nil }

                        weightedConfidenceSum += Double(candidate.confidence) * Double(line.count)
                        weightedConfidenceCount += line.count
                        return OCRLineObservation(
                            text: line,
                            confidence: Double(candidate.confidence),
                            boundingBox: observation.boundingBox
                        )
                    }
                let originalPageText = observations
                    .map(\.text)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reflowedPageText = layoutOrderedText(for: observations)

                if !originalPageText.isEmpty {
                    originalChunks.append(originalPageText)
                }

                if !reflowedPageText.isEmpty {
                    reflowedChunks.append(reflowedPageText)
                }

                if index == 0 {
                    firstPageReflowedText = reflowedPageText.isEmpty ? originalPageText : reflowedPageText
                }
            }

            let reflowedText = reflowedChunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let originalText = originalChunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let chosenText = reflowedText.isEmpty ? originalText : reflowedText
            guard !chosenText.isEmpty else { return nil }

            let confidence = weightedConfidenceCount > 0
                ? weightedConfidenceSum / Double(weightedConfidenceCount)
                : nil
            return OCRTextResult(
                text: chosenText,
                firstPageText: firstPageReflowedText,
                originalText: originalText.isEmpty ? nil : originalText,
                confidence: confidence
            )
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

struct OCRTextResult: Equatable, Sendable {
    let text: String
    let firstPageText: String?
    let originalText: String?
    let confidence: Double?

    init(
        text: String,
        firstPageText: String? = nil,
        originalText: String?,
        confidence: Double?
    ) {
        self.text = text
        self.firstPageText = firstPageText
        self.originalText = originalText
        self.confidence = confidence
    }
}

struct OCRLineObservation: Equatable, Sendable {
    let text: String
    let confidence: Double
    let boundingBox: CGRect

    var midY: Double {
        Double(boundingBox.midY)
    }

    var minX: Double {
        Double(boundingBox.minX)
    }

    var height: Double {
        Double(boundingBox.height)
    }
}

func layoutOrderedText(for observations: [OCRLineObservation]) -> String {
    guard !observations.isEmpty else { return "" }

    var rows: [OCRRow] = []
    let sorted = observations.sorted { lhs, rhs in
        if abs(lhs.midY - rhs.midY) > 0.0001 {
            return lhs.midY > rhs.midY
        }

        return lhs.minX < rhs.minX
    }

    for observation in sorted {
        if let index = rows.firstIndex(where: { $0.accepts(observation) }) {
            rows[index].append(observation)
        } else {
            rows.append(OCRRow(observation: observation))
        }
    }

    return rows
        .sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.0001 {
                return lhs.midY > rhs.midY
            }

            return lhs.minX < rhs.minX
        }
        .map(\.text)
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private struct OCRRow {
    private(set) var observations: [OCRLineObservation]
    private(set) var midY: Double
    private(set) var averageHeight: Double

    init(observation: OCRLineObservation) {
        observations = [observation]
        midY = observation.midY
        averageHeight = observation.height
    }

    var minX: Double {
        observations.map(\.minX).min() ?? 0
    }

    var text: String {
        observations
            .sorted { lhs, rhs in lhs.minX < rhs.minX }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func accepts(_ observation: OCRLineObservation) -> Bool {
        let tolerance = max(averageHeight * 0.7, 0.02)
        return abs(observation.midY - midY) <= tolerance
    }

    mutating func append(_ observation: OCRLineObservation) {
        observations.append(observation)
        midY = observations.map(\.midY).reduce(0, +) / Double(observations.count)
        averageHeight = observations.map(\.height).reduce(0, +) / Double(observations.count)
    }
}
