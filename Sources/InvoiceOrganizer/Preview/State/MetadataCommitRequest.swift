struct MetadataCommitRequest: Equatable {
    let artifactID: PhysicalArtifact.ID
    let metadata: DocumentMetadata
}
