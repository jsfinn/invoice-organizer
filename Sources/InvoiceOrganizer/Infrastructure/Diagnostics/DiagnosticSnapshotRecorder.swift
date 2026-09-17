import Foundation

/// Writes one diagnostic dump per app version, in two passes.
///
/// The launch pass captures the raw blobs before any scan can touch them. The second
/// pass overwrites that same file once the first reconcile has produced the computed
/// view. Splitting it that way means a crash during reconcile still leaves the
/// irreplaceable half on disk.
@MainActor
final class DiagnosticSnapshotRecorder {
    private let defaults: UserDefaults
    private let directory: URL
    private var launchDump: (url: URL, dump: LibraryStateDump)?

    static let lastDumpedVersionKey = "diagnostics.lastDumpedAppVersion"

    init(
        defaults: UserDefaults = .standard,
        directory: URL = LibraryStateDump.diagnosticsDirectory
    ) {
        self.defaults = defaults
        self.directory = directory
    }

    /// Best-effort: a diagnostic that cannot be written must not stop the app from
    /// launching.
    func captureRawAtLaunch() {
        guard !Self.isRunningInTests else { return }

        let version = LibraryStateDump.runningAppVersion
        guard defaults.string(forKey: Self.lastDumpedVersionKey) != version else { return }

        let dump = LibraryStateDump(raw: LibraryStateExtractor.extract(), computed: nil)
        let url = LibraryStateDump.fileURL(in: directory, capturedAt: dump.capturedAt)
        guard (try? dump.write(to: url)) != nil else { return }

        launchDump = (url, dump)
    }

    /// Fills in the computed half of the launch dump. The closure is only evaluated
    /// when there is a dump waiting for it, so a normal launch does not pay for
    /// walking the folders.
    func completeLaunchCapture(computed: () -> ComputedLibraryState) {
        guard let (url, dump) = launchDump else { return }
        launchDump = nil

        guard (try? dump.addingComputed(computed()).write(to: url)) != nil else { return }
        defaults.set(dump.appVersion, forKey: Self.lastDumpedVersionKey)
    }

    /// The menu command's path: always a fresh dump, and failures are the caller's
    /// to report.
    func exportSnapshot(computed: ComputedLibraryState) throws -> URL {
        let dump = LibraryStateDump(raw: LibraryStateExtractor.extract(), computed: computed)
        return try dump.write(to: LibraryStateDump.fileURL(in: directory, capturedAt: dump.capturedAt))
    }

    var diagnosticsDirectory: URL { directory }

    /// A test run builds `AppModel` many times over; none of those launches should
    /// leave OCR text in the real Application Support folder.
    static var isRunningInTests: Bool {
        Bundle.main.bundleURL.pathExtension == "xctest"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

// MARK: - Building the computed view

extension ComputedLibraryState {
    static func make(
        artifacts: [PhysicalArtifact],
        metadata: (PhysicalArtifact.ID) -> DocumentMetadata,
        roots: [URL]
    ) -> ComputedLibraryState {
        ComputedLibraryState(
            artifacts: artifacts.map { artifact in
                let resolved = metadata(artifact.id)
                return ComputedArtifactState(
                    artifactID: artifact.id,
                    path: artifact.fileURL.standardizedFileURL.path,
                    location: artifact.location,
                    status: artifact.status,
                    contentHash: artifact.contentHash,
                    vendor: resolved.vendor,
                    invoiceDate: resolved.invoiceDate,
                    invoiceNumber: resolved.invoiceNumber,
                    documentType: resolved.documentType
                )
            },
            files: roots.flatMap(ScannedFileDescriptor.descriptors(under:))
                .sorted { $0.path < $1.path }
        )
    }
}

extension ScannedFileDescriptor {
    static func descriptors(under root: URL) -> [ScannedFileDescriptor] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                return nil
            }
            return ScannedFileDescriptor(
                path: url.standardizedFileURL.path,
                filename: url.lastPathComponent,
                byteCount: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate
            )
        }
    }
}
