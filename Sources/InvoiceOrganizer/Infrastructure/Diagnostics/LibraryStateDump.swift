import Foundation

/// A versioned snapshot of everything needed to reason about a library offline:
/// the legacy blobs verbatim, plus what the UI actually resolved from them.
///
/// `computed` is nil in the copy written at launch, before any scan has run. The
/// launch copy exists so a crash during reconcile still leaves the irreplaceable
/// raw blobs on disk.
struct LibraryStateDump: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let capturedAt: Date
    let appVersion: String
    let raw: LegacyLibraryState
    let computed: ComputedLibraryState?

    init(
        capturedAt: Date = Date(),
        appVersion: String = LibraryStateDump.runningAppVersion,
        raw: LegacyLibraryState,
        computed: ComputedLibraryState?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.capturedAt = capturedAt
        self.appVersion = appVersion
        self.raw = raw
        self.computed = computed
    }

    func addingComputed(_ computed: ComputedLibraryState) -> LibraryStateDump {
        LibraryStateDump(
            capturedAt: capturedAt,
            appVersion: appVersion,
            raw: raw,
            computed: computed
        )
    }

    static var runningAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

/// What the app resolved from the raw blobs: one row per artifact as the UI shows
/// it, plus the file listing the scan saw. Comparing these two across a migration
/// is how we prove nothing moved that should not have.
struct ComputedLibraryState: Codable, Sendable {
    let artifacts: [ComputedArtifactState]
    let files: [ScannedFileDescriptor]
}

struct ComputedArtifactState: Codable, Sendable {
    let artifactID: String
    let path: String
    let location: InvoiceLocation
    let status: InvoiceStatus
    let contentHash: String?
    let vendor: String?
    let invoiceDate: Date?
    let invoiceNumber: String?
    let documentType: DocumentType?
}

struct ScannedFileDescriptor: Codable, Sendable {
    let path: String
    let filename: String
    let byteCount: Int
    let modifiedAt: Date?
}

// MARK: - On-disk representation

extension LibraryStateDump {
    /// Dates encode as their default `Double` form rather than ISO8601 so the raw
    /// section round-trips bit-for-bit into the phase 2 migration. ISO8601 without
    /// fractional seconds would quietly truncate `extractedAt`.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var diagnosticsDirectory: URL {
        ApplicationSupportDirectory.url.appendingPathComponent("diagnostics", isDirectory: true)
    }

    static func fileURL(in directory: URL, capturedAt: Date) -> URL {
        // Colons are legal in a filename but Finder renders them as slashes, so the
        // stamp uses the compact ISO8601 form.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return directory.appendingPathComponent(
            "state-\(formatter.string(from: capturedAt)).json",
            isDirectory: false
        )
    }

    /// Writes atomically so a reader never sees a half-written dump, and so the
    /// launch copy is replaced in one step once `computed` is available.
    @discardableResult
    func write(to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.encoder().encode(self).write(to: url, options: .atomic)
        return url
    }

    static func read(from url: URL) throws -> LibraryStateDump {
        try JSONDecoder().decode(LibraryStateDump.self, from: Data(contentsOf: url))
    }
}

/// The app's own folder under Application Support, created on demand.
enum ApplicationSupportDirectory {
    static let folderName = "Invoice Organizer"

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }
}