import AppKit
import Foundation

@MainActor
final class ArtifactAccessCoordinator {
    func sourcePathDisplay(for handle: ArtifactHandle) -> String {
        handle.fileURL.path
    }

    func processedFolderPreviewPath(
        for artifact: PhysicalArtifact,
        metadata: DocumentMetadata,
        processedRoot: URL?
    ) -> String? {
        switch artifact.location {
        case .inbox:
            return nil
        case .processing, .processed:
            let trimmedVendor = metadata.vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedVendor.isEmpty else { return "" }
            return ArchivePathBuilder.destinationFolder(
                root: processedRoot ?? URL(fileURLWithPath: "/Processed"),
                vendor: metadata.vendor
            ).path
        }
    }

    func dragExportURL(for handle: ArtifactHandle) throws -> URL {
        try DragExportService.dragURL(for: handle)
    }

    func fileIcon(for handle: ArtifactHandle) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: handle.fileURL.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    func fileExists(for handle: ArtifactHandle) -> Bool {
        FileManager.default.fileExists(atPath: handle.fileURL.path)
    }

    func rotate(handle: ArtifactHandle, quarterTurns: Int) async throws {
        try await Task.detached(priority: .userInitiated) {
            try InvoiceFileRotator.rotateFile(
                at: handle.fileURL,
                fileType: handle.fileType,
                quarterTurns: quarterTurns
            )
        }.value
    }

    func updatedContentHash(for handle: ArtifactHandle) -> String? {
        try? FileHasher.sha256(for: handle.fileURL)
    }
}
