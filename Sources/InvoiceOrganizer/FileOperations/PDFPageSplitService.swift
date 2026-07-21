import Foundation
import PDFKit

/// Splits a multi-page PDF into one single-page PDF per page.
///
/// This is the inverse of `PDFJoinService` and is distinct from `FileDuplicationService`
/// (which reproduces the entire source page-for-page). Each output file contains exactly
/// one page copied losslessly from the source; the source itself is left untouched.
enum PDFPageSplitService {
    /// The number of pages in the PDF at `source`, or `0` if it cannot be read.
    static func pageCount(of source: URL) -> Int {
        PDFDocument(url: source)?.pageCount ?? 0
    }

    /// Writes one single-page PDF per page of `source` into `folder`, named
    /// "`baseName` - Page N.pdf". Returns the created file URLs in page order.
    ///
    /// The operation is all-or-nothing: if any page fails to write, files created so
    /// far are removed before the error is rethrown.
    @discardableResult
    static func split(source: URL, into folder: URL, baseName: String) throws -> [URL] {
        guard let document = PDFDocument(url: source) else {
            throw SplitError.unreadableFile(source)
        }
        guard document.pageCount >= 2 else {
            throw SplitError.notMultiPage
        }

        let sanitizedBase = sanitize(baseName)
        var createdURLs: [URL] = []

        do {
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else {
                    throw SplitError.unreadableFile(source)
                }

                let singlePageDocument = PDFDocument()
                singlePageDocument.insert(page, at: 0)

                let destinationURL = uniquePageURL(
                    in: folder,
                    baseName: sanitizedBase,
                    pageNumber: pageIndex + 1,
                    alreadyCreated: createdURLs
                )
                let temporaryURL = temporaryPDFURL(for: destinationURL)
                guard singlePageDocument.write(to: temporaryURL) else {
                    throw SplitError.writeFailed
                }
                do {
                    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw SplitError.writeFailed
                }
                createdURLs.append(destinationURL)
            }
        } catch {
            for url in createdURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        return createdURLs
    }

    // MARK: - Helpers

    private static func sanitize(_ baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Document" : trimmed
        return base.replacingOccurrences(of: "/", with: "-")
    }

    private static func uniquePageURL(
        in folder: URL,
        baseName: String,
        pageNumber: Int,
        alreadyCreated: [URL]
    ) -> URL {
        let fileManager = FileManager.default
        let reserved = Set(alreadyCreated.map { $0.standardizedFileURL.path })

        func candidate(_ name: String) -> URL {
            folder.appendingPathComponent(name).appendingPathExtension("pdf")
        }

        func isAvailable(_ url: URL) -> Bool {
            !fileManager.fileExists(atPath: url.path)
                && !reserved.contains(url.standardizedFileURL.path)
        }

        let primary = candidate("\(baseName) - Page \(pageNumber)")
        if isAvailable(primary) {
            return primary
        }

        var suffix = 2
        while true {
            let alternate = candidate("\(baseName) - Page \(pageNumber) (\(suffix))")
            if isAvailable(alternate) {
                return alternate
            }
            suffix += 1
        }
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

    enum SplitError: LocalizedError {
        case unreadableFile(URL)
        case notMultiPage
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let fileURL):
                return "Could not read \(fileURL.lastPathComponent) to split it into pages."
            case .notMultiPage:
                return "This PDF has only one page, so there is nothing to split."
            case .writeFailed:
                return "The split pages could not be saved."
            }
        }
    }
}
