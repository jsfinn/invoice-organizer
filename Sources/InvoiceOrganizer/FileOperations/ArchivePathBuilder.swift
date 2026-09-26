import Foundation

struct ProcessedInvoiceMetadata {
    let vendor: String
    let invoiceDate: Date
    let invoiceNumber: String?
    /// Only present on filenames written by builds that appended a processing
    /// timestamp. Modern filenames carry an invoice number in that position instead.
    let processedAt: Date?
}

enum ArchivePathBuilder {
    static func destinationFolder(root: URL, vendor: String?) -> URL {
        let normalizedVendor = normalizedVendorName(from: vendor)
        let leadingLetter = String(normalizedVendor.prefix(1)).uppercased()
        let folderLetter = leadingLetter.rangeOfCharacter(from: CharacterSet.letters) == nil ? "#" : leadingLetter

        return root
            .appendingPathComponent(folderLetter, isDirectory: true)
            .appendingPathComponent(normalizedVendor, isDirectory: true)
    }

    static func normalizedVendorName(from vendor: String?) -> String {
        let trimmed = vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sanitized = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return sanitized.isEmpty ? "Misc" : sanitized
    }

    static func processedFilename(vendor: String?, invoiceDate: Date, invoiceNumber: String?, originalFileURL: URL) -> String {
        let invoiceNumberPart = normalizedFileComponent(invoiceNumber)
        let components: [String] = [
            normalizedVendorName(from: vendor),
            invoiceDateFormatter.string(from: invoiceDate),
            invoiceNumberPart
        ]
        .compactMap { component in
            guard let component, !component.isEmpty else { return nil }
            return component
        }

        let baseName = components.isEmpty ? originalFileURL.deletingPathExtension().lastPathComponent : components.joined(separator: "-")
        let fileExtension = originalFileURL.pathExtension
        if fileExtension.isEmpty {
            return baseName
        }

        return "\(baseName).\(fileExtension)"
    }

    static func processingFilename(vendor: String?, invoiceDate: Date?, invoiceNumber: String?, originalFileURL: URL) -> String {
        let invoiceNumberPart = normalizedFileComponent(invoiceNumber)
        let components: [String] = [
            normalizedVendorName(from: vendor),
            invoiceDate.map { invoiceDateFormatter.string(from: $0) },
            invoiceNumberPart
        ]
        .compactMap { component in
            guard let component, !component.isEmpty else { return nil }
            return component
        }

        guard !components.isEmpty else {
            return originalFileURL.lastPathComponent
        }

        let baseName = components.joined(separator: "-")
        let fileExtension = originalFileURL.pathExtension
        if fileExtension.isEmpty {
            return baseName
        }

        return "\(baseName).\(fileExtension)"
    }

    /// Reads back what `processedFilename` writes: `Vendor-yyyy-MM-dd[-invoiceNumber]`.
    ///
    /// Older builds wrote `Vendor-yyyy-MM-dd-yyyyMMdd-HHmmss`, where the trailing
    /// component is a processing timestamp rather than an invoice number. Both forms
    /// are still on disk, so the suffix is classified by whether it parses as that
    /// timestamp.
    ///
    /// Note the round trip is lossy for invoice numbers: `normalizedFileComponent`
    /// rewrites `/` and `:` to `-`, so a parsed number is a hint only and must never
    /// overwrite a stored one.
    static func processedMetadata(from fileURL: URL) -> ProcessedInvoiceMetadata? {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let pattern = #"^(.+?)-(\d{4}-\d{2}-\d{2})(?:-(.+))?$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(baseName.startIndex..<baseName.endIndex, in: baseName)
        guard let match = regex.firstMatch(in: baseName, range: range),
              let vendorRange = Range(match.range(at: 1), in: baseName),
              let invoiceRange = Range(match.range(at: 2), in: baseName),
              let invoiceDate = invoiceDateFormatter.date(from: String(baseName[invoiceRange])) else {
            return nil
        }

        let suffix = Range(match.range(at: 3), in: baseName).map { String(baseName[$0]) }
        let processedAt = suffix.flatMap(processedTimestampFormatter.date(from:))

        return ProcessedInvoiceMetadata(
            vendor: String(baseName[vendorRange]),
            invoiceDate: invoiceDate,
            invoiceNumber: processedAt == nil ? suffix : nil,
            processedAt: processedAt
        )
    }
}

private func normalizedFileComponent(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    return trimmed
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
}

// The invoice date is a date-only value that the user picks and sees in the local
// calendar (DatePicker, list/detail displays) and that the LLM extractor parses in the
// local timezone. The filename must reflect that same local calendar day, otherwise an
// invoice `Date` whose time-of-day straddles midnight in UTC (e.g. an evening timestamp
// for a user behind UTC) would be written to the filename as the previous/next day.
private let invoiceDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let processedTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
}()
