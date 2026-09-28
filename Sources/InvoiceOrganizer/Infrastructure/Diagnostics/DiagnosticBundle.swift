import Foundation

/// An export in flight, or one finished and waiting to be acknowledged. The status
/// bar owns clearing it: the finished archive stays on screen until the user has
/// actually been shown where it landed.
enum DiagnosticExportState {
    case exporting(fraction: Double)
    case finished(URL)
}

/// Where each copied tree came from, so a bundle opened on another machine maps
/// back onto local folders without having to infer roots from artifact paths.
struct DiagnosticBundleManifest: Codable, Sendable {
    struct Root: Codable, Sendable {
        let role: FolderRole
        let originalPath: String
        let folderName: String
        let fileCount: Int
        let byteCount: Int
    }

    let capturedAt: Date
    let appVersion: String
    let stateFileName: String
    let roots: [Root]
}

enum DiagnosticBundleError: LocalizedError {
    case archiveFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .archiveFailed(status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Compressing the bundle failed with status \(status)."
                : "Compressing the bundle failed: \(detail)"
        }
    }
}

/// A state dump packaged with the files it describes, as one archive that can be
/// carried to another machine and replayed against a build.
///
/// The Archive folder is deliberately left out. The reconciler only ever passes it
/// as an exclusion, so nothing in it becomes an artifact and none of it is
/// reproducible state - it would be weight and nothing else.
///
/// Invoices are already-compressed PDFs and JPEGs, so zipping a real library saves
/// around 2% and costs about fifteen seconds per gigabyte. The archive exists to
/// make the bundle one thing to carry, not to make it smaller.
enum DiagnosticBundle {
    static let stateFileName = "state.json"
    static let manifestFileName = "manifest.json"

    static var includedRoles: [FolderRole] {
        FolderRole.allCases.filter { $0 != .duplicates }
    }

    /// Writes the bundle to `destination`, which is the archive itself rather than a
    /// folder to put it in, so a large export is written once instead of being
    /// staged and then copied to wherever the user asked for it.
    ///
    /// A configured folder that is missing on disk is skipped rather than fatal: a
    /// partial bundle still diagnoses more than no bundle, and its absence from the
    /// manifest records what happened.
    static func write(
        dump: LibraryStateDump,
        folderSettings: FolderSettings,
        to destination: URL,
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        let fileManager = FileManager.default
        let stagingParent = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = stagingParent.appendingPathComponent(
            destination.deletingPathExtension().lastPathComponent,
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingParent) }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try dump.write(to: staging.appendingPathComponent(stateFileName, isDirectory: false))

        var roots: [DiagnosticBundleManifest.Root] = []
        for role in includedRoles {
            guard let source = folderSettings.url(for: role),
                  fileManager.fileExists(atPath: source.path) else {
                continue
            }

            let folderName = role.rawValue
            let copied = staging.appendingPathComponent(folderName, isDirectory: true)
            try fileManager.copyItem(at: source, to: copied)

            let descriptors = ScannedFileDescriptor.descriptors(under: copied)
            roots.append(
                DiagnosticBundleManifest.Root(
                    role: role,
                    originalPath: source.standardizedFileURL.path,
                    folderName: folderName,
                    fileCount: descriptors.count,
                    byteCount: descriptors.reduce(0) { $0 + $1.byteCount }
                )
            )
        }

        let manifest = DiagnosticBundleManifest(
            capturedAt: dump.capturedAt,
            appVersion: dump.appVersion,
            stateFileName: stateFileName,
            roots: roots
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent(manifestFileName, isDirectory: false),
            options: .atomic
        )

        // Progress tracks the compression phase only. Staging is around a second
        // even for a multi-gigabyte library, where compressing is fifteen times
        // per gigabyte, so spreading the bar across both would make it lurch.
        try archive(
            staging,
            to: destination,
            uncompressedByteCount: roots.reduce(0) { $0 + $1.byteCount },
            onProgress: onProgress
        )
        return destination
    }

    /// Suggested filename for a save panel, stamped the same way dumps are so a
    /// bundle and a loose dump sort together.
    static func suggestedFileName(capturedAt: Date) -> String {
        let stateName = LibraryStateDump
            .fileURL(in: URL(fileURLWithPath: "/"), capturedAt: capturedAt)
            .deletingPathExtension()
            .lastPathComponent
        return "diagnostics-\(stateName.dropFirst("state-".count)).zip"
    }

    /// Compresses with `ditto` rather than `NSFileCoordinator`'s `.forUploading`
    /// because the coordinator only hands back its temporary archive once it is
    /// finished, in a directory whose name is generated per call. There is nothing
    /// to watch while it works. Naming the output ourselves means its size can be
    /// sampled as it grows, and since these files compress by roughly 2% those
    /// bytes track progress closely.
    private static func archive(
        _ directory: URL,
        to destination: URL,
        uncompressedByteCount: Int,
        onProgress: @Sendable (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, destination.path]
        process.standardError = errorPipe

        try process.run()

        // This runs on a background task of its own, so sampling on this thread
        // costs nothing the caller was going to use.
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.15)
            guard uncompressedByteCount > 0 else { continue }
            let written = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
            onProgress(min(Double(written ?? 0) / Double(uncompressedByteCount), 1))
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw DiagnosticBundleError.archiveFailed(status: process.terminationStatus, message: message)
        }

        onProgress(1)
    }
}
