import Foundation

enum DuplicateMatchKind: String, Equatable, Sendable {
    case identicalFile
    case sameDocument
}

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
    var matchKind: DuplicateMatchKind?
    var vetoReason: String?
    var pendingReason: String?

    var id: String { documentID }
}

struct PossibleSameInvoiceMatch: Identifiable, Equatable, Sendable {
    let documentID: String
    let matchedArtifactID: String
    let matchedFileURL: URL
    let matchedLocation: InvoiceLocation
    let artifactCount: Int
    let metadata: DocumentMetadata

    var id: String { documentID }
}

struct DedupSummary: Equatable, Sendable {
    let groupingStatus: GroupingStatus
    let identityDescription: String?
    let extractionState: ExtractionState
    let comparisons: [DedupComparison]

    enum GroupingStatus: Equatable, Sendable {
        case singleton
        case identicalCopy(referenceFile: String)
        case duplicateGrouped(referenceFile: String, reason: String)
    }

    enum ExtractionState: Equatable, Sendable {
        case notStarted
        case textOnly
        case complete
    }
}

struct DedupComparison: Identifiable, Equatable, Sendable {
    let documentID: String
    let fileName: String
    let location: InvoiceLocation
    let artifactCount: Int
    let decision: Decision
    let textScore: Double?
    let identityRelation: IdentityRelation?

    var id: String { documentID }

    enum Decision: Equatable, Sendable {
        case grouped
        case vetoed(reason: String)
        case belowThreshold
        case pending(reason: String)

        var sortPriority: Int {
            switch self {
            case .grouped: return 0
            case .pending: return 1
            case .vetoed: return 2
            case .belowThreshold: return 3
            }
        }
    }

    enum IdentityRelation: Equatable, Sendable {
        case positiveMatch
        case conflict(reason: String)
        case noIdentity
    }
}

struct ArtifactDuplicateCluster: Equatable, Identifiable, Sendable {
    let artifactIDs: [PhysicalArtifact.ID]

    var id: String {
        artifactIDs.sorted().joined(separator: "|")
    }
}
