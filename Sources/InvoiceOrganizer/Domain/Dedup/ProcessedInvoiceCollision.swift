import Foundation

enum ProcessedInvoiceCollision {
    static func firstMatch(
        metadata: DocumentMetadata,
        artifacts: [PhysicalArtifact],
        metadataByArtifactID: [PhysicalArtifact.ID: DocumentMetadata],
        excludingArtifactID: PhysicalArtifact.ID
    ) -> PhysicalArtifact? {
        guard let key = IdentityKey(metadata: metadata) else { return nil }

        return artifacts.first { artifact in
            guard artifact.id != excludingArtifactID,
                  artifact.location == .processed,
                  let otherKey = IdentityKey(metadata: metadataByArtifactID[artifact.id] ?? .empty) else {
                return false
            }
            return otherKey == key
        }
    }
}

private struct IdentityKey: Hashable {
    let vendor: String
    let year: Int
    let month: Int
    let day: Int
    let invoiceNumber: String

    init?(metadata: DocumentMetadata) {
        guard let vendor = Self.normalized(metadata.vendor),
              let invoiceNumber = Self.normalized(metadata.invoiceNumber),
              let invoiceDate = metadata.invoiceDate else {
            return nil
        }

        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: invoiceDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }

        self.vendor = vendor
        self.year = year
        self.month = month
        self.day = day
        self.invoiceNumber = invoiceNumber
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
