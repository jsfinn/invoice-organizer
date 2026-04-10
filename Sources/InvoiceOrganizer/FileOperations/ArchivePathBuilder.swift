import Foundation

struct ProcessedInvoiceMetadata {
    let vendor: String
    let invoiceDate: Date
    let processedAt: Date
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

    static func processedMetadata(from fileURL: URL) -> ProcessedInvoiceMetadata? {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let pattern = #"^(.*)-(\d{4}-\d{2}-\d{2})-(\d{8}-\d{6})$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(location: 0, length: baseName.utf16.count)
        guard let match = regex.firstMatch(in: baseName, range: range),
              match.numberOfRanges == 4,
              let vendorRange = Range(match.range(at: 1), in: baseName),
              let invoiceRange = Range(match.range(at: 2), in: baseName),
              let processedRange = Range(match.range(at: 3), in: baseName),
              let invoiceDate = invoiceDateFormatter.date(from: String(baseName[invoiceRange])),
              let processedAt = processedTimestampFormatter.date(from: String(baseName[processedRange])) else {
            return nil
        }

        return ProcessedInvoiceMetadata(
            vendor: String(baseName[vendorRange]),
            invoiceDate: invoiceDate,
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

private let invoiceDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
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
