import Foundation

struct PreviewSessionID: Hashable {
    let handle: ArtifactHandle

    init(invoice: PhysicalArtifact) {
        handle = invoice.handle
    }
}
