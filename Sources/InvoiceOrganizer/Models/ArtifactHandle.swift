import Foundation

struct ArtifactHandle: Hashable, Sendable {
    let artifactID: PhysicalArtifact.ID
    let fileURL: URL
    let fileType: InvoiceFileType
    let contentHash: String?
    let addedAt: Date
    let displayName: String

    init(
        artifactID: PhysicalArtifact.ID,
        fileURL: URL,
        fileType: InvoiceFileType,
        contentHash: String?,
        addedAt: Date,
        displayName: String
    ) {
        self.artifactID = artifactID
        self.fileURL = fileURL
        self.fileType = fileType
        self.contentHash = contentHash
        self.addedAt = addedAt
        self.displayName = displayName
    }

    init(artifact: PhysicalArtifact) {
        self.init(
            artifactID: artifact.id,
            fileURL: artifact.fileURL,
            fileType: artifact.fileType,
            contentHash: artifact.contentHash,
            addedAt: artifact.addedAt,
            displayName: artifact.name
        )
    }
}

extension PhysicalArtifact {
    var handle: ArtifactHandle {
        ArtifactHandle(artifact: self)
    }
}
