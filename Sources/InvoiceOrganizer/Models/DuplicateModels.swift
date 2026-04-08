import Foundation

struct DuplicateInfo: Equatable, Sendable {
    let duplicateOfPath: String
    let reason: String
}

struct DuplicateSimilarity: Identifiable, Equatable, Sendable {
    let documentID: String
    let matchedArtifactID: String
    let matchedFileURL: URL
    let matchedLocation: InvoiceLocation
    let artifactCount: Int
    let score: Double
    let meetsThreshold: Bool

    var id: String { documentID }
}

struct ArtifactDuplicateCluster: Equatable, Identifiable, Sendable {
    let artifactIDs: [PhysicalArtifact.ID]

    var id: String {
        artifactIDs.sorted().joined(separator: "|")
    }
}
